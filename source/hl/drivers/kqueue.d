module hl.drivers.kqueue;

version(OSX):

import std.datetime;
import std.string;
import std.container;
import std.stdio;
import std.exception;
import std.experimental.logger;

import core.sys.posix.fcntl: open, O_RDONLY;
import core.sys.posix.unistd: close;

import core.sys.darwin.sys.event;

import core.sys.posix.signal : timespec;
import core.stdc.stdint : intptr_t, uintptr_t;
import core.stdc.string: strerror;
import core.stdc.errno: errno;

import hl.events;

//enum : short {
//    EVFILT_READ =      (-1),
//    EVFILT_WRITE =     (-2),
//    EVFILT_AIO =       (-3),    /* attached to aio requests */
//    EVFILT_VNODE =     (-4),    /* attached to vnodes */
//    EVFILT_PROC =      (-5),    /* attached to struct proc */
//    EVFILT_SIGNAL =    (-6),    /* attached to struct proc */
//    EVFILT_TIMER =     (-7),    /* timers */
//    EVFILT_MACHPORT =  (-8),    /* Mach portsets */
//    EVFILT_FS =        (-9),    /* Filesystem events */
//    EVFILT_USER =      (-10),   /* User events */
//            /* (-11) unused */
//    EVFILT_VM =        (-12)   /* Virtual memory events */
//}

//enum : ushort {
///* actions */
//    EV_ADD  =                0x0001,          /* add event to kq (implies enable) */
//    EV_DELETE =              0x0002,          /* delete event from kq */
//    EV_ENABLE =              0x0004,          /* enable event */
//    EV_DISABLE =             0x0008          /* disable event (not reported) */
//}

//struct kevent_t {
//    uintptr_t       ident;          /* identifier for this event */
//    short           filter;         /* filter for event */
//    ushort          flags;          /* general flags */
//    uint            fflags;         /* filter-specific flags */
//    intptr_t        data;           /* filter-specific data */
//    void*           udata;
//}

//extern(C) int kqueue() @safe @nogc nothrow;
//extern(C) int kevent(int kqueue_fd, const kevent_t *events, int ne, const kevent_t *events, int ne,timespec* timeout) @safe @nogc nothrow;

struct NativeEventLoopImpl {
    immutable bool   native = true;
    immutable string _name = "OSX";
    @disable this(this) {};
    private {
        bool running = true;
        enum MAXEVENTS = 16;

        int  kqueue_fd = -1;  // interface to kernel
        int  in_index;

        kevent_t[MAXEVENTS] in_events;
        kevent_t[MAXEVENTS] out_events;

        RedBlackTree!Timer      timers;

    }
    void initialize() {
        if ( kqueue_fd == -1) {
            kqueue_fd = kqueue();
        }
        debug tracef("kqueue_fd=%d", kqueue_fd);
        timers = new RedBlackTree!Timer();

    }
    void deinit() {
        debug tracef("deinit");
        close(kqueue_fd);
        kqueue_fd = -1;
        in_index = 0;
        timers = null;
    }
    void stop() {
        running = false;
    }
    void run(Duration d) {
        running = true;

        SysTime deadline = Clock.currTime + d;
        debug tracef("evl run for %s", d);

        while(running) {
            Duration delta = deadline - Clock.currTime;
            if ( delta < 0.seconds ) {
                delta = 0.seconds;
            }
            auto ds = delta.split!("seconds", "nsecs");
            timespec ts = {
                tv_sec:  cast(typeof(timespec.tv_sec))ds.seconds,
                tv_nsec: cast(typeof(timespec.tv_nsec))ds.nsecs
            };
            if ( in_index > 0 ) {
                debug tracef("Flush %d events %s", in_index, in_events);
                auto rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
                in_index = 0;
            }
            debug tracef("waiting for events %s", ts);
            int ready = kevent(kqueue_fd,
                                cast(kevent_t*)&in_events[0], in_index,
                                cast(kevent_t*)&out_events[0], MAXEVENTS,
                                &ts);
            debug tracef("kevent returned %d events", ready);
            if ( ready < 0 ) {
                errorf("kevent returned error %s", fromStringz(strerror(errno)));
                return;
            }
            if ( ready == 0 ) {
                debug trace("kevent timedout and no events to process");
                return;
            }
            in_index = 0;
            foreach(i; 0..ready) {
                if ( !running ) {
                    break;
                }
                auto e = out_events[i];
                debug tracef("got kevent[%d] %s, data: %d, udata: %0x", i, e, e.data, e.udata);
                switch (e.filter) {
                    case EVFILT_TIMER:
                        auto now = Clock.currTime;
                        assert(!timers.empty, "timers empty on timer event");
                        //assert(timers.front._expires <= now, "%s - %s".format(timers.front, now));
                        while ( !timers.empty && timers.front._expires <= now ) {
                            debug tracef("processing %s, lag: %s", timers.front, Clock.currTime - timers.front._expires);
                            Timer t = timers.front;
                            HandlerDelegate h = t._handler;
                            timers.removeFront;
                            h(AppEvent.TMO);
                        }
                        if ( ! timers.empty ) {
                            now = Clock.currTime;
                            _mod_kernel_timer(timers.front, timers.front._expires - now);
                        } else {
                            //_del_kernel_timer();
                        }
                        break;
                    default:
                        break;
                }
            }
        }
    }
    void start_timer(Timer t) {
        //debug tracef("insert timer: %s - %X", t, cast(void*)t);
        //_add_kernel_timer(t);
        debug tracef("insert timer %s - %X", t, cast(void*)t);
        if ( timers.empty ) {
            auto d = t._expires - Clock.currTime;
            _add_kernel_timer(t, d);
            timers.insert(t);
            return;
        }
        auto next = timers.front;
        if ( t < next ) {
            auto d = next._expires - Clock.currTime;
            _mod_kernel_timer(t, d);
        }
        timers.insert(t);
    }
    void stop_timer(Timer t) {
        //debug tracef("remove timer %s", t);
        //_del_kernel_timer(t);
        debug tracef("remove timer %s", t);

        if ( t == timers.front ) {
            debug trace("we have to del this timer from kernel");
            timers.removeFront();
            _del_kernel_timer(t);
            if ( ! timers.empty ) {
                // we can change kernel timer to next if it in the future,
                // or leave it at the front and it will fired at the next run
                auto next = timers.front;
                auto d = next._expires - Clock.currTime;
                if ( d > 0.seconds ) {
                    _mod_kernel_timer(timers.front, d);
                }
            }
        } else {
            // do not change anything in kernel
            auto r = timers.equalRange(t);
            timers.remove(r);
        }
    }
    void _add_kernel_timer(in Timer t, in Duration d) {
        debug tracef("add kernel timer %s", t);
        intptr_t delay_ms = d.split!"msecs".msecs;
        kevent_t e;
        e.ident = 0;
        e.filter = EVFILT_TIMER;
        e.flags = EV_ADD | EV_ONESHOT;
        e.data = delay_ms;
        e.udata = cast(void*)t;
        if ( in_index == MAXEVENTS ) {
            // flush
            int rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
            enforce(rc>=0, "_del_kernel_timer: kevent %s, %s".format(fromStringz(strerror(errno)), in_events[0..in_index]));
            in_index = 0;
        }
        in_events[in_index++] = e;
    }
    alias _mod_kernel_timer = _add_kernel_timer;
    void _del_kernel_timer(in Timer t) {
        debug trace("del kernel timer");
        kevent_t e;
        e.ident = 0;
        e.filter = EVFILT_TIMER;
        e.flags = EV_DELETE;
        if ( in_index == MAXEVENTS ) {
            // flush
            int rc = kevent(kqueue_fd, &in_events[0], in_index, null, 0, null);
            enforce(rc>=0, "_del_kernel_timer: kevent %s, %s".format(fromStringz(strerror(errno)), in_events[0..in_index]));
            in_index = 0;
        }
        in_events[in_index++] = e;
    }
}

auto appEventToSysEvent(AppEvent ae) {
    import core.bitop;
    assert( popcnt(ae) == 1, "Set one event at a time");
    assert( ae <= AppEvent.CONN, "You can ask for IN,OUT,CONN events");
    switch ( ae ) {
        case AppEvent.IN:
            return EVFILT_READ;
        case AppEvent.OUT:
            return EVFILT_WRITE;
        case AppEvent.CONN:
            return EVFILT_READ;
        default:
            throw new Exception("You can't wait for event %X".format(ae));
    }
}
AppEvent sysEventToAppEvent(short se) {
    final switch ( se ) {
        case EVFILT_READ:
            return AppEvent.IN;
        case EVFILT_WRITE:
            return AppEvent.OUT;
        // default:
        //     throw new Exception("Unexpected event %d".format(se));
    }
}
unittest {
    import std.exception;
    import core.exception;

    assert(appEventToSysEvent(AppEvent.IN)==EVFILT_READ);
    assert(appEventToSysEvent(AppEvent.OUT)==EVFILT_WRITE);
    assert(appEventToSysEvent(AppEvent.CONN)==EVFILT_READ);
    //assertThrown!AssertError(appEventToSysEvent(AppEvent.IN | AppEvent.OUT));
    assert(sysEventToAppEvent(EVFILT_READ) == AppEvent.IN);
    assert(sysEventToAppEvent(EVFILT_WRITE) == AppEvent.OUT);
}
