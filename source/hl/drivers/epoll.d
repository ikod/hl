module hl.drivers.epoll;

version(linux):

import std.datetime;
import std.string;
import std.container;
import std.exception;
import std.experimental.logger;
import std.algorithm.comparison: max;
import core.stdc.string: strerror;
import core.stdc.errno: errno, EAGAIN;

import core.sys.linux.epoll;
import core.sys.linux.timerfd;
import core.sys.linux.sys.signalfd;

import core.sys.posix.unistd: close, read;
import core.sys.posix.time : itimerspec, CLOCK_MONOTONIC , timespec;

import hl.events;

struct NativeEventLoopImpl {
    immutable bool   native = true;
    immutable string _name = "epoll";
    private {
        bool                    running = true;
        enum                    MAXEVENTS = 1024;
        int                     epoll_fd = -1;
        int                     timer_fd = -1;
        int                     signal_fd = -1;
        sigset_t                mask;

        align(1)                epoll_event[MAXEVENTS] events;

        RedBlackTree!Timer      timers;
        Timer[]                 overdue;    // timers added with expiration in past
        Signal[][int]           signals;
    }
    @disable this(this) {}

    void initialize() {
        if ( epoll_fd == -1 ) {
            epoll_fd = epoll_create(MAXEVENTS);
        }
        if ( timer_fd == -1 ) {
            timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
        }
        timers = new RedBlackTree!Timer();
    }
    void deinit() {
        close(epoll_fd);
        epoll_fd = -1;
        close(timer_fd);
        timer_fd = -1;
        timers = null;
    }

    void stop() {
        running = false;
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

        running = true;
        immutable bool runIndefinitely = (d == Duration.max);

        /**
         * eventloop will exit when we reach deadline
         * it is allowed to have d == 0.seconds,
         * which mean we wil run events once
        **/
        SysTime deadline = Clock.currTime + d;
        debug tracef("evl run %s",runIndefinitely? "indefinitely": "for %s".format(d));


        while( running ) {

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

            int timeout_ms = runIndefinitely ?
                -1 :
                _calculate_timeout(deadline);

            uint ready = epoll_wait(epoll_fd, &events[0], MAXEVENTS, timeout_ms);
            if ( ready == 0 ) {
                debug trace("epoll timedout and no events to process");
                return;
            }
            if ( ready < 0 ) {
                errorf("epoll_wait returned error %s", fromStringz(strerror(errno)));
            }
            enforce(ready >= 0);
            if ( ready > 0 ) {
                foreach(i; 0..ready) {
                    auto e = events[i];
                    debug tracef("got event %s", e);
                    CanPoll p = cast(CanPoll)e.data.ptr;

                    if ( p.id.fd == timer_fd ) {
                        // with EPOLLET flag I dont have to read from timerfd, otherwise I ahve to:
                        // ubyte[8] v;
                        // read(timer_fd, &v[0], 8);

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
                    if ( p.id.fd == signal_fd ) {
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
                    }
                    //HandlerDelegate h = cast(HandlerDelegate)e.data.ptr;
                    //AppEvent appEvent = AppEvent(sysEventToAppEvent(e.events), -1);
                    //h(appEvent);
                }
            }
        }
    }
    void start_timer(Timer t) {
        debug tracef("insert timer %s - %X", t, cast(void*)t);
        t.id.fd = timer_fd;
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

    void stop_timer(Timer t) {
        debug tracef("remove timer %s", t);

        if ( t != timers.front ) {
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

    void _add_kernel_timer(Timer t, in Duration d) {
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
        e.data.ptr = cast(void*)t;
        rc = epoll_ctl(epoll_fd, EPOLL_CTL_ADD, timer_fd, &e);
        enforce(rc >= 0, "epoll_ctl add(%s): %s".format(e, fromStringz(strerror(errno))));
    }
    void _mod_kernel_timer(Timer t, in Duration d) {
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
        e.data.ptr = cast(void*)t;
        rc = epoll_ctl(epoll_fd, EPOLL_CTL_MOD, timer_fd, &e);
        enforce(rc >= 0);
    }
    void _del_kernel_timer() {
        debug trace("del kernel timer");
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = timer_fd;
        int rc = epoll_ctl(epoll_fd, EPOLL_CTL_DEL, timer_fd, &e);
        enforce(rc >= 0, "epoll_ctl del(%s): %s".format(e, fromStringz(strerror(errno))));
    }

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
        s.id.fd = signal_fd;
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
            e.data.ptr = cast(void*)s;
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

    void start_poll(FileDescriptor d, AppEvent ev) pure nothrow @safe {
        //immutable fd = d._fileno;
        //d._polling |= ev;
        //files[fd] = d;
    }
    void stop_poll(FileDescriptor d, AppEvent ev) {
    
    }
}