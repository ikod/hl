module hl.drivers.select;

import std.datetime;
import std.container;
import std.experimental.logger;

version(Windows) {
    import core.sys.windows.winsock2;
}
version(Posix) {
    import core.sys.posix.sys.select;
}

import hl.events;

struct FallbackEventLoopImpl {
    immutable string _name = "select";

    private {
        fd_set                  read_fds;
        fd_set                  write_fds;
        fd_set                  err_fds;

        RedBlackTree!Timer      timers;

        bool                    running = true;
    }

    @disable this(this) {};

    void initialize() {
        timers = new RedBlackTree!Timer();
    }
    void deinit() {
        timers = null;
    }
    void stop() {
        debug trace("mark eventloop as stopped");
        running = false;
    }

    void run(Duration d) {
        running = true;

        timeval tv;
        int fdmax;
        SysTime deadline = Clock.currTime + d;
        debug tracef("evl run for %s", d);

        while (running) {

            auto now = Clock.currTime;
            if ( ! timers.empty ) {
                d = timers.front._expires - now;
            } else {
                d = deadline - now;
            }
            auto converted = d.split!("seconds", "usecs");
            tv.tv_sec  = cast(typeof(tv.tv_sec))converted.seconds;
            tv.tv_usec = cast(typeof(tv.tv_usec))converted.usecs;

            FD_ZERO(&read_fds);
            FD_ZERO(&write_fds);
            FD_ZERO(&err_fds);

            auto ready = select(fdmax+1, &read_fds, &write_fds, null, &tv);
            if ( ready == 0 ) {
                // timeout
                if ( timers.empty ) {
                    debug trace("select timedout and no timers active");
                    return;
                }
                auto _t = timers.front;
                debug tracef("processing %s, lag: %s", _t, Clock.currTime - _t._expires);
                timers.removeFront;
                HandlerDelegate h = _t._handler;
                h(AppEvent.TMO);
            }
        }
    }

    void start_timer(Timer t) {
        debug tracef("insert timer: %s", t);
        timers.insert(t);
    }
    void stop_timer(Timer t) {
        debug tracef("remove timer %s", t);
        auto r = timers.equalRange(t);
        timers.remove(r);
    }
}