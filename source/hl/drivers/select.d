module hl.drivers.select;

import std.datetime;
import std.container;
import std.experimental.logger;
import std.string;
import std.algorithm.comparison: min, max;
import std.exception: enforce;

version(Windows) {
    import core.sys.windows.winsock2;
}
version(Posix) {
    import core.sys.posix.sys.select;
}

import core.stdc.string: strerror;
import core.stdc.errno;
import core.stdc.signal;

import hl.events;

//
// TODO add support for multiple select event loops
//
private enum                            sig_array_length = 64;
private static int[sig_array_length]    last_signal;
private static int                      last_signal_index;

extern(C) void sig_catcher(int signum) nothrow @nogc {
    last_signal[last_signal_index++] = signum;
}

struct FallbackEventLoopImpl {
    immutable string _name = "select";

    private {
        fd_set                  read_fds;
        fd_set                  write_fds;
        fd_set                  err_fds;

        RedBlackTree!Timer      timers;
        Signal[][int]           signals;

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

    /**
     * Find shortest interval between now->deadline, now->earliest timer
     * If deadline expired or timer in past - set zero wait time
     */
    timeval* _calculate_timeval(SysTime deadline, timeval* tv) {
        SysTime now = Clock.currTime;
        Duration d = deadline - now;
        if ( ! timers.empty ) {
            d = min(d, timers.front._expires - now);
        }
        d = max(d, 0.seconds);
        auto converted = d.split!("seconds", "usecs");
        tv.tv_sec  = cast(typeof(tv.tv_sec))converted.seconds;
        tv.tv_usec = cast(typeof(tv.tv_usec))converted.usecs;
        return tv;
    }
    timeval* _calculate_timeval(timeval* tv) {
        SysTime  now = Clock.currTime;
        Duration d;
        d = timers.front._expires - now;
        d = max(d, 0.seconds);
        auto converted = d.split!("seconds", "usecs");
        tv.tv_sec  = cast(typeof(tv.tv_sec))converted.seconds;
        tv.tv_usec = cast(typeof(tv.tv_usec))converted.usecs;
        return tv;
    }
    void run(Duration d) {

        running = true;

        immutable bool runIndefinitely = (d == Duration.max);
        SysTime now = Clock.currTime;
        SysTime deadline;
        timeval tv;
        timeval* wait;

        if ( ! runIndefinitely ) {
            deadline = now + d;
        }

        debug tracef("evl run %s",runIndefinitely? "indefinitely": "for %s".format(d));

        int fdmax = -1;

        while (running) {

            while ( !timers.empty && timers.front._expires <= now) {
                debug tracef("processing overdue  %s, lag: %s", timers.front, Clock.currTime - timers.front._expires);
                Timer t = timers.front;
                HandlerDelegate h = t._handler;
                timers.removeFront;
                try {
                    h(AppEvent.TMO);
                } catch (Exception e) {
                    errorf("Uncaught exception: %s", e);
                }
                now = Clock.currTime;
            }

            FD_ZERO(&read_fds);
            FD_ZERO(&write_fds);
            FD_ZERO(&err_fds);

            wait = (runIndefinitely && timers.empty)  ?
                          null
                        : _calculate_timeval(deadline, &tv);
            if ( runIndefinitely && timers.empty ) {
                wait = null;
            } else
            if ( runIndefinitely && !timers.empty ) {
                wait = _calculate_timeval(&tv);
            } else
                wait = _calculate_timeval(deadline, &tv);

            debug tracef("waiting for events %s", wait is null?"forewer":"%s".format(*wait));
            auto ready = select(fdmax+1, &read_fds, &write_fds, null, wait);
            debug tracef("returned %d events", ready);
            if ( ready < 0 && errno == EINTR ) {
                int s_ind;
                while(s_ind < last_signal_index) {
                    int signum = last_signal[s_ind];
                    assert(signals[signum].length > 0);
                    foreach(s; signals[signum]) {
                        debug tracef("processing signal handler %s", s);
                        try {
                            SigHandlerDelegate h = s._handler;
                            h(signum);
                        } catch (Exception e) {
                            errorf("Uncaught exception: %s", e);
                        }
                    }
                    s_ind++;
                }
                last_signal_index = 0;
                continue;
            }
            if ( ready < 0 ) {
                errorf("on call: (%s, %s, %s, %s)", fdmax+1, read_fds, write_fds, tv);
                errorf("select returned error %s", fromStringz(strerror(errno)));
            }
            enforce(ready >= 0);
            if ( ready == 0 ) {
                // Timedout
                //
                // For select there can be two reasons for ready == 0:
                // 1. we reached deadline
                // 2. we have timer event
                //
                if ( timers.empty ) {
                    // there were no timers, so this can be only timeout
                    debug trace("select timedout and no timers active");
                    assert(Clock.currTime >= deadline);
                    return;
                }
                now = Clock.currTime;
                if ( !runIndefinitely && now >= deadline ) {
                    debug trace("deadline reached");
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

                if ( timers.front._expires <= now) do {
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
        signal(s._signum, &sig_catcher);
        debug tracef("adding handler for signum %d: %x", s._signum, &this);
    }
    void _del_kernel_signal(Signal s) {
        signal(s._signum, SIG_DFL);
        debug tracef("deleted handler for signum %d: %x", s._signum, &this);
    }
}