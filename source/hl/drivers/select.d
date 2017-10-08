module hl.drivers.select;

import std.datetime;
import std.container;
import std.experimental.logger;
import std.string;

version(Windows) {
    import core.sys.windows.winsock2;
}
version(Posix) {
    import core.sys.posix.sys.select;
}

import core.stdc.string: strerror;
import core.stdc.errno: errno;

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
            if ( d < 0.seconds ) {
                debug trace("deadline reached");
                return;
            }
            auto converted = d.split!("seconds", "usecs");
            tv.tv_sec  = cast(typeof(tv.tv_sec))converted.seconds;
            tv.tv_usec = cast(typeof(tv.tv_usec))converted.usecs;

            FD_ZERO(&read_fds);
            FD_ZERO(&write_fds);
            FD_ZERO(&err_fds);

            auto ready = select(fdmax+1, &read_fds, &write_fds, null, &tv);
            debug tracef("returned %d events", ready);
            if ( ready < 0 ) {
                errorf("select returned error %s", fromStringz(strerror(errno)));
                return;
            }
            if ( ready == 0 ) {
                // timeout
                if ( timers.empty ) {
                    debug trace("select timedout and no timers active");
                    return;
                }
                /*
                 * Invariants for timers
                 * ---------------------
                 * timer list must not be empty at event.
                 * we have to receive event only on the earliest timer in list
                */
                assert(!timers.empty, "timers empty on timer event");
                /* */

                now = Clock.currTime;

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