module hl.drivers.epoll;

version(linux):

import std.datetime;
import std.string;
import std.container;
import std.exception;
import std.experimental.logger;

import core.stdc.string: strerror;
import core.stdc.errno: errno;

import core.sys.linux.epoll;
import core.sys.linux.timerfd;
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
        align(1)                epoll_event[MAXEVENTS] events;

        RedBlackTree!Timer      timers;

    }
    @disable this(this) {};
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
    void run(Duration d) {
        running = true;
        int timeout_ms = cast(int)d.total!"msecs";
        while( running ) {
            uint ready = epoll_wait(epoll_fd, &events[0], MAXEVENTS, timeout_ms);
            if ( ready == 0 ) {
                debug trace("epoll timedout and no events to process");
                return;
            }
            if ( ready < 0 ) {
                error("epoll returned error");
                return;
            }
            if ( ready > 0 ) {
                foreach(i; 0..ready) {
                    auto e = events[i];
                    debug tracef("got event %s", e);
                    if ( e.data.fd == timer_fd ) {
                        ubyte[8] v;
                        read(timer_fd, &v[0], 8);
                        auto now = Clock.currTime;
                        assert(!timers.empty, "timers empty on timer event");
                        assert(timers.front._expires <= now);
                        while ( !timers.empty && timers.front._expires <= now ) {
                            debug tracef("processing %s, lag: %s", timers.front, Clock.currTime - timers.front._expires);
                            Timer t = timers.front;
                            HandlerDelegate h = t._handler;
                            timers.removeFront;
                            h(AppEvent.TMO);
                        }
                        if ( ! timers.empty ) {
                            _mod_kernel_timer(timers.front, timers.front._expires - now);
                        } else {
                            _del_kernel_timer();
                        }
                        continue;
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
        if ( timers.empty ) {
            _add_kernel_timer(t);
            timers.insert(t);
            return;
        }
        if ( t < timers.front ) {
            auto d = t._expires - Clock.currTime;
            _mod_kernel_timer(t, d);
        }
        timers.insert(t);
    }
    void stop_timer(Timer t) {
        debug tracef("remove timer %s", t);
        assert(timer_fd>=0, "Timer file is not opened");

        if ( t == timers.front ) {
            debug trace("we have to del this timer from kernel");
            timers.removeFront();
            if ( ! timers.empty ) {
                // we can change kernel timer to next if it in the future,
                // or leave it at the front and it will fired at the next run
                auto next = timers.front;
                auto d = next._expires - Clock.currTime;
                if ( d > 0.seconds ) {
                    _mod_kernel_timer(timers.front, d);
                }
            } else {
                // no next timers - just delete it from kernel
                _del_kernel_timer();
            }
        } else {
            // do not change anything in kernel
            auto r = timers.equalRange(t);
            timers.remove(r);
        }
    }
    void _add_kernel_timer(in Timer t) {
        debug trace("add kernel timer");
        itimerspec itimer;
        auto d = t._expires - Clock.currTime;
        itimer.it_value.tv_sec = cast(typeof(itimer.it_value.tv_sec)) d.split!("seconds", "nsecs")().seconds;
        itimer.it_value.tv_nsec = cast(typeof(itimer.it_value.tv_nsec)) d.split!("seconds", "nsecs")().nsecs;
        int rc = timerfd_settime(timer_fd, 0, &itimer, null);
        enforce(rc >= 0, "timerfd_settime(%s): %s".format(itimer, fromStringz(strerror(errno))));
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = timer_fd;
        rc = epoll_ctl(epoll_fd, EPOLL_CTL_ADD, timer_fd, &e);
        enforce(rc >= 0, "epoll_ctl add(%s): %s".format(e, fromStringz(strerror(errno))));
    }
    void _mod_kernel_timer(in Timer t, in Duration d) {
        debug tracef("mod kernel timer to %s", t);
        itimerspec itimer;
        auto ds = d.split!("seconds", "nsecs");
        itimer.it_value.tv_sec = cast(typeof(itimer.it_value.tv_sec)) ds.seconds;
        itimer.it_value.tv_nsec = cast(typeof(itimer.it_value.tv_nsec)) ds.nsecs;
        int rc = timerfd_settime(timer_fd, 0, &itimer, null);
        enforce(rc >= 0, "timerfd_settime(%s): %s".format(itimer, fromStringz(strerror(errno))));
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = timer_fd;
        rc = epoll_ctl(epoll_fd, EPOLL_CTL_MOD, timer_fd, &e);
        enforce(rc >= 0);
    }
    void _del_kernel_timer() {
        debug trace("del kernel timer");
        epoll_event e;
        e.events = EPOLLIN;
        e.data.fd = timer_fd;
        e.data.fd = timer_fd;
        int rc = epoll_ctl(epoll_fd, EPOLL_CTL_DEL, timer_fd, &e);
        enforce(rc >= 0, "epoll_ctl del(%s): %s".format(e, fromStringz(strerror(errno))));
    }
}