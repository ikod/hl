module hl.events;

import std.datetime;
import std.exception;
import std.container;

enum AppEvent : ubyte {
    IN   = 0x01,
    OUT  = 0x02,
    ERR  = 0x04,
    CONN = 0x08,
    HUP  = 0x10,
    TMO  = 0x20,
};

alias HandlerDelegate = void delegate(AppEvent);
alias SigHandlerDelegate = void delegate(int);

class CanPoll {
    union Id {
        int     fd;
    };

    Id  id;
}

class NotFoundException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

final class Timer: CanPoll {
    private static ulong timer_id = 1;
    package {
        immutable ulong           _id;
        immutable SysTime         _expires;
        immutable HandlerDelegate _handler;
        //void*                     _data;
    }
    int opCmp(in Timer other) const nothrow pure @safe {
        int timeCmp = _expires.opCmp(other._expires);
        if ( timeCmp != 0 ) {
            return timeCmp;
        }
        return _id < other._id ? -1 : 1;
    }
    this(Duration d, HandlerDelegate h) {
        _expires = Clock.currTime + d;
        _handler = h;
        _id = timer_id;
        timer_id++;
    }
    this(SysTime e, HandlerDelegate h) {
        enforce(e != SysTime.init, "Unintialized expires for new timer");
        enforce(h != HandlerDelegate.init, "Unitialized handler for new Timer");
        _expires = e;
        _handler = h;
        _id = timer_id++;
    }
    override string toString() const {
        import std.format: format;
        return "timer: expires: %s, id: %d".format(_expires, _id);
    }
}

final class Signal : CanPoll {
    private static ulong signal_id = 1;
    package {
        immutable int   _signum;
        immutable ulong _id;
        immutable SigHandlerDelegate _handler;
    }

    this(int signum, SigHandlerDelegate h) {
        _signum = signum;
        _handler = h;
        _id = signal_id++;
    }
    int opCmp(in Signal other) const nothrow pure @safe {
        if ( _signum == other._signum ) {
            return _id < other._id ? -1 : 1;
        }
        return _signum < other._signum ? -1 : 1;
    }
    override string toString() const {
        import std.format: format;
        return "signal: signum: %d, id: %d".format(_signum, _id);
    }
}