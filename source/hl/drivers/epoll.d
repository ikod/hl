module hl.drivers.epoll;

version(linux):

import std.datetime;
import std.string;
import std.container;
import std.exception;
import std.experimental.logger;
import std.typecons;

import std.experimental.allocator;
import std.experimental.allocator.mallocator;

import std.algorithm.comparison: max;
import core.stdc.string: strerror;
import core.stdc.errno: errno, EAGAIN;

import core.sys.linux.epoll;
import core.sys.linux.timerfd;
import core.sys.linux.sys.signalfd;

import core.sys.posix.unistd: close, read;
import core.sys.posix.time : itimerspec, CLOCK_MONOTONIC , timespec;

import hl.events;
import hl.common;

struct NativeEventLoopImpl {
    immutable bool   native = true;
    immutable string _name = "epoll";
    private {
        bool                    stopped = false;
        enum                    MAXEVENTS = 1024;
        int                     epoll_fd = -1;
        int                     timer_fd = -1;
        int                     signal_fd = -1;
        sigset_t                mask;

        align(1)                epoll_event[MAXEVENTS] events;

        RedBlackTree!Timer      timers;
        Timer[]                 overdue;    // timers added with expiration in past
        Signal[][int]           signals;
        //FileHandlerFunction[int] fileHandlers;
        FileEventHandler[]      fileHandlers;
        CircBuff!NotificationDelivery   notificationsQueue;

    }
    @disable this(this) {}

    void initialize() @safe nothrow {
        if ( epoll_fd == -1 ) {
            epoll_fd = (() @trusted  => epoll_create(MAXEVENTS))();
        }
        if ( timer_fd == -1 ) {
            timer_fd = (() @trusted => timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK))();
        }
        timers = new RedBlackTree!Timer();
        fileHandlers = Mallocator.instance.makeArray!FileEventHandler(16*1024);
    }
    void deinit() @trusted {
        close(epoll_fd);
        epoll_fd = -1;
        close(timer_fd);
        timer_fd = -1;
        timers = null;
        Mallocator.instance.dispose(fileHandlers);
    }

    void stop() @safe {
        stopped = true;
    }

    int _calculate_timeout(SysTime deadline) {
        Duration delta = deadline - Clock.currTime;
        delta = max(delta, 0.seconds);
        return cast(int)delta.total!"msecs";
    }
    /**
    *
    **/
    void run(Duration d) {

        immutable bool runIndefinitely = (d == Duration.max);

        /**
         * eventloop will exit when we reach deadline
         * it is allowed to have d == 0.seconds,
         * which mean we wil run events once
        **/
        SysTime deadline = Clock.currTime + d;
        debug tracef("evl run %s",runIndefinitely? "indefinitely": "for %s".format(d));

        scope ( exit )
        {
            stopped = false;
        }

        while( !stopped ) {

            //
            // handle user events(notifications)
            //
            auto counter = notificationsQueue.Size * 10;
            while(!notificationsQueue.empty){
                auto nd = notificationsQueue.get();
                Notification n = nd._n;
                Broadcast b = nd._broadcast;
                n.handler(b);
                counter--;
                enforce(counter > 0, "Can't clear notificatioinsQueue");
            }
            //auto counter = notificationsQueue.Size * 10;
            //while(!notificationsQueue.empty){
            //    auto n = notificationsQueue.get();
            //    n.handler();
            //    counter--;
            //    enforce(counter > 0, "Can't clear notificatioinsQueue");
            //}

            while (overdue.length > 0) {
                // execute timers with requested negative delay
                Timer t = overdue[0];
                overdue = overdue[1..$];
                debug tracef("execute overdue %s", t);
                HandlerDelegate h = t._handler;
                try {
                    h(AppEvent.TMO);
                } catch (Exception e) {
                    errorf("Uncaught exception: %s", e);
                }
            }
            if (stopped) {
                break;
            }

            int timeout_ms = runIndefinitely ?
                -1 :
                _calculate_timeout(deadline);

            uint ready = epoll_wait(epoll_fd, &events[0], MAXEVENTS, timeout_ms);
            debug tracef("got %d events", ready);
            if ( ready == 0 ) {
                debug trace("epoll timedout and no events to process");
                return;
            }
            if ( ready < 0 ) {
                errorf("epoll_wait returned error %s", fromStringz(strerror(errno)));
            }
            enforce(ready >= 0);
            debug tracef("events: %s", events[0..ready]);
            foreach(i; 0..ready) {
                auto e = events[i];
                debug tracef("got event %s", e);
                int fd = e.data.fd;

                if ( fd == timer_fd ) {
                    // with EPOLLET flag I dont have to read from timerfd, otherwise I ahve to:
                    // ubyte[8] v;
                    // read(timer_fd, &v[0], 8);
                    debug tracef("timer event");
                    auto now = Clock.currTime;
                    /*
                     * Invariants for timers
                     * ---------------------
                     * timer list must not be empty at event.
                     * we have to receive event only on the earliest timer in list
                    **/
                    assert(!timers.empty, "timers empty on timer event");
                    assert(timers.front._expires <= now);

                    do {
                        debug tracef("processing %s, lag: %s", timers.front, Clock.currTime - timers.front._expires);
                        Timer t = timers.front;
                        HandlerDelegate h = t._handler;
                        timers.removeFront;
                        try {
                            h(AppEvent.TMO);
                        } catch (Exception e) {
                            errorf("Uncaught exception: %s", e);
                        }
                        now = Clock.currTime;
                    } while (!timers.empty && timers.front._expires <= now );

                    if ( ! timers.empty ) {
                        Duration kernel_delta = timers.front._expires - now;
                        assert(kernel_delta > 0.seconds);
                        _mod_kernel_timer(timers.front, kernel_delta);
                    } else {
                        // delete kernel timer so we can add it next time
                        _del_kernel_timer();
                    }
                    continue;
                }
                if ( fd == signal_fd ) {
                    enum siginfo_items = 8;
                    signalfd_siginfo[siginfo_items] info;
                    debug trace("got signal");
                    assert(signal_fd != -1);
                    while (true) {
                        auto rc = read(signal_fd, &info, info.sizeof);
                        if ( rc < 0 && errno == EAGAIN ) {
                            break;
                        }
                        enforce(rc > 0);
                        auto got_signals = rc / signalfd_siginfo.sizeof;
                        debug tracef("read info %d, %s", got_signals, info[0..got_signals]);
                        foreach(si; 0..got_signals) {
                            auto signum = info[si].ssi_signo;
                            debug tracef("signum: %d", signum);
                            foreach(s; signals[signum]) {
                                debug tracef("processing signal handler %s", s);
                                try {
                                    SigHandlerDelegate h = s._handler;
                                    h(signum);
                                } catch (Exception e) {
                                    errorf("Uncaught exception: %s", e);
                                }
                            }
                        }
                    }
                    continue;
                }
                AppEvent ae;
                if ( e.events & EPOLLIN ) {
                    ae |= AppEvent.IN;
                }
                if ( e.events & EPOLLOUT ) {
                    ae |= AppEvent.OUT;
                }
                debug tracef("process event %02x on fd: %s, handler: %s", e.events, e.data.fd, fileHandlers[fd]);
                try {
                    fileHandlers[fd].eventHandler(e.data.fd, ae);
                } catch (Exception e) {
                    errorf("On file handler: %s", e);
                }
                //HandlerDelegate h = cast(HandlerDelegate)e.data.ptr;
                //AppEvent appEvent = AppEvent(sysEventToAppEvent(e.events), -1);
                //h(appEvent);
            }
        }
    }
    void start_timer(Timer t) @safe {
        debug tracef("insert timer %s", t);
        if ( timers.empty || t < timers.front ) {
            auto d = t._expires - Clock.currTime;
            d = max(d, 0.seconds);
            if ( d == 0.seconds ) {
                overdue ~= t;
                return;
            }
            if ( timers.empty ) {
                _add_kernel_timer(t, d);
            } else {
                _mod_kernel_timer(t, d);
            }
        }
        timers.insert(t);
    }

    void stop_timer(Timer t) @safe {
        debug tracef("remove timer %s", t);

        if ( t !is timers.front ) {
            auto r = timers.equalRange(t);
            timers.remove(r);
            return;
        }

        timers.removeFront();
        debug trace("we have to del this timer from kernel or set to next");
        if ( !timers.empty ) {
            // we can change kernel timer to next,
            // If next timer expired - set delta = 0 to run on next loop invocation
            auto next = timers.front;
            auto d = next._expires - Clock.currTime;
            d = max(d, 0.seconds);
            _mod_kernel_timer(timers.front, d);
            return;
        }
        _del_kernel_timer();
    }

    void _add_kernel_timer(Timer t, in Duration d) @trusted {
        debug trace("add kernel timer");
        assert(d > 0.seconds);
        itimerspec itimer;
        auto ds = d.split!("seconds", "nsecs");
        itimer.it_value.tv_sec = cast(typeof(itimer.it_value.tv_sec)) ds.seconds;
        itimer.it_value.tv_nsec = cast(typeof(itimer.it_value.tv_nsec)) ds.nsecs;
        int rc = timerfd_settime(timer_fd, 0, &itimer, null);
        enforce(rc >= 0, "timerfd_settime(%s): %s".format(itimer, fromStringz(strerror(errno))));
        epoll_event e;
        e.events = EPOLLIN|EPOLLET;
        e.data.fd = timer_fd;
        rc = epoll_ctl(epoll_fd, EPOLL_CTL_ADD, timer_fd, &e);
        enforce(rc >= 0, "epoll_ctl add(%s): %s".format(e, fromStringz(strerror(errno))));
    }
    void _mod_kernel_timer(Timer t, in Duration d) @trusted {
        debug tracef("mod kernel timer to %s", t);
        assert(d > 0.seconds);
        itimerspec itimer;
        auto ds = d.split!("seconds", "nsecs");
        itimer.it_value.tv_sec = cast(typeof(itimer.it_value.tv_sec)) ds.seconds;
        itimer.it_value.tv_nsec = cast(typeof(itimer.it_value.tv_nsec)) ds.nsecs;
        int rc = timerfd_settime(timer_fd, 0, &itimer, null);
        enforce(rc >= 0, "timerfd_settime(%s): %s".format(itimer, fromStringz(strerror(errno))));
        epoll_event e;
        e.events = EPOLLIN|EPOLLET;
        e.data.fd = timer_fd;
        rc = epoll_ctl(epoll_fd, EPOLL_CTL_MOD, timer_fd, &e);
        enforce(rc >= 0);
    }
    void _del_kernel_timer() @trusted {
        debug trace("del kernel timer");
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = timer_fd;
        int rc = epoll_ctl(epoll_fd, EPOLL_CTL_DEL, timer_fd, &e);
        enforce(rc >= 0, "epoll_ctl del(%s): %s".format(e, fromStringz(strerror(errno))));
    }
    //
    // notifications
    //
    pragma(inline)
    void processNotification(Notification ue, Broadcast broadcast) @safe {
        ue.handler(broadcast);
    }
    void postNotification(Notification notification, Broadcast broadcast = No.broadcast) @safe {
        debug trace("posting notification");
        if ( !notificationsQueue.full )
        {
            debug trace("put notification");
            notificationsQueue.put(NotificationDelivery(notification, broadcast));
            debug trace("put notification done");
            return;
        }
        // now try to find space for next notification
        auto retries = 10 * notificationsQueue.Size;
        while(notificationsQueue.full && retries > 0)
        {
            retries--;
            auto nd = notificationsQueue.get();
            Notification _n = nd._n;
            Broadcast _b = nd._broadcast;
            processNotification(_n, _b);
        }
        enforce(!notificationsQueue.full, "Can't clear space for next notification in notificatioinsQueue");
        notificationsQueue.put(NotificationDelivery(notification, broadcast));
        debug trace("posting notification - done");
    }


    //void postNotification(Notification notification, Broadcast broadcast = No.broadcast) @safe {
    //    debug trace("posting notification");
    //    if ( !notificationsQueue.full )
    //    {
    //        notificationsQueue.put(NotificationDelivery(notification, broadcast));
    //        return;
    //    }
    //    // now try to find space for next notification
    //    auto retries = 10 * notificationsQueue.Size;
    //    while(notificationsQueue.full && retries > 0)
    //    {
    //        retries--;
    //        auto nd = notificationsQueue.get();
    //        Notification _n = nd._n;
    //        Broadcast _b = nd._broadcast;
    //        processNotification(_n, _b);
    //    }
    //    enforce(!notificationsQueue.full, "Can't clear space for next notification in notificatioinsQueue");
    //    notificationsQueue.put(NotificationDelivery(notification, broadcast));
    //}

    //
    // signals
    //
    void start_signal(Signal s) {
        debug tracef("start signal %s", s);
        debug tracef("signals: %s", signals);
        auto r = s._signum in signals;
        if ( r is null || r.length == 0 ) {
            // enable signal only through kevent
            _add_kernel_signal(s);
        }
        signals[s._signum] ~= s;
    }
    void stop_signal(Signal s) {
        debug trace("stop signal");
        auto r = s._signum in signals;
        if ( r is null ) {
            throw new NotFoundException("You tried to stop signal that was not started");
        }
        Signal[] new_row;
        foreach(a; *r) {
            if (a._id == s._id) {
                continue;
            }
            new_row ~= a;
        }
        if ( new_row.length == 0 ) {
            *r = null;
            _del_kernel_signal(s);
            // reenable old signal behaviour
        } else {
            *r = new_row;
        }
        debug tracef("new signals %d row %s", s._signum, new_row);
    }
    void _add_kernel_signal(Signal s) {
        debug tracef("add kernel signal %d, id: %d", s._signum, s._id);
        sigset_t m;
        sigemptyset(&m);
        sigaddset(&m, s._signum);
        sigprocmask(SIG_BLOCK, &m, null);

        sigaddset(&mask, s._signum);
        if ( signal_fd == -1 ) {
            signal_fd = signalfd(-1, &mask, SFD_NONBLOCK|SFD_CLOEXEC);
            epoll_event e;
            e.events = EPOLLIN|EPOLLET;
            e.data.fd = signal_fd;
            auto rc = epoll_ctl(epoll_fd, EPOLL_CTL_ADD, signal_fd, &e);
            enforce(rc >= 0, "epoll_ctl add(%s): %s".format(e, fromStringz(strerror(errno))));
        } else {
            signalfd(signal_fd, &mask, 0);
        }

    }
    void _del_kernel_signal(Signal s) {
        debug tracef("del kernel signal %d, id: %d", s._signum, s._id);
        sigset_t m;
        sigemptyset(&m);
        sigaddset(&m, s._signum);
        sigprocmask(SIG_UNBLOCK, &m, null);
        sigdelset(&mask, s._signum);
        assert(signal_fd != -1);
        signalfd(signal_fd, &mask, 0);
    }
    void wait_for_user_event(int event_id, FileEventHandler handler) @safe {
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = event_id;
        auto rc = (() @trusted => epoll_ctl(epoll_fd, EPOLL_CTL_ADD, event_id, &e))();
        enforce(rc >= 0, "epoll_ctl add(%s): %s".format(e, s_strerror(errno)));
        fileHandlers[event_id] = handler;
    }
    void stop_wait_for_user_event(int event_id, FileEventHandler handler) @safe {
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = event_id;
        auto rc = (() @trusted => epoll_ctl(epoll_fd, EPOLL_CTL_DEL, event_id, &e))();
        fileHandlers[event_id] = null;
    }

    int get_kernel_id() pure @safe nothrow @nogc {
        return epoll_fd;
    }

    //
    // files/sockets
    //
    void detach(int fd) @safe {
        fileHandlers[fd] = null;
    }
    void start_poll(int fd, AppEvent ev, FileEventHandler f) @trusted {
        epoll_event e;
        e.events = appEventToSysEvent(ev);
        e.data.fd = fd;
        auto rc = epoll_ctl(epoll_fd, EPOLL_CTL_ADD, fd, &e);
        enforce(rc >= 0, "epoll_ctl add(%s): %s".format(e, fromStringz(strerror(errno))));
        fileHandlers[fd] = f;
    }

    void stop_poll(int fd, AppEvent ev) @trusted {
        epoll_event e;
        e.events = appEventToSysEvent(ev);
        e.data.fd = fd;
        auto rc = epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, &e);
    }
    auto appEventToSysEvent(AppEvent ae) pure @safe {
        import core.bitop;
        assert( popcnt(ae) == 1, "Set one event at a time, you tried %x, %s".format(ae, appeventToString(ae)));
        assert( ae <= AppEvent.CONN, "You can ask for IN,OUT,CONN events");
        switch ( ae ) {
            case AppEvent.IN:
                return EPOLLIN;
            case AppEvent.OUT:
                return EPOLLOUT;
            //case AppEvent.CONN:
            //    return EVFILT_READ;
            default:
                throw new Exception("You can't wait for event %X".format(ae));
        }
    }
}

