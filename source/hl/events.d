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

private static ulong timer_id = 1000;

class CanPoll {
    union Id {
        int     fd;
    };

    Id  id;
}

final class Timer: CanPoll {
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
        _id = timer_id;
        timer_id++;
    }
    override string toString() const {
        import std.format: format;
        return "expires: %s, id: %d".format(_expires, _id);
    }
}

