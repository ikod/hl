module hl.events;

import std.datetime;
import std.exception;
import std.container;

import nbuff;

enum AppEvent : int {
    NONE = 0x00,
    IN   = 0x01,
    OUT  = 0x02,
    ERR  = 0x04,
    CONN = 0x08,
    HUP  = 0x10,
    TMO  = 0x20,
    ALL  = 0x3f
}
private immutable string[int] _names;

static this() {
    _names = [
        0:"NONE",
        1:"IN",
        2:"OUT",
        4:"ERR",
        8:"CONN",
       16:"HUP",
       32:"TMO"
    ];
}

alias HandlerDelegate = void delegate(AppEvent) @safe;
alias SigHandlerDelegate = void delegate(int) @safe;
alias FileHandlerFunction = void function(int, AppEvent) @safe;

string appeventToString(AppEvent ev) @safe pure {
    import std.format;
    import std.range;

    string[] a;
    with(AppEvent) {
        foreach(e; [IN,OUT,ERR,CONN,HUP,TMO]) {
            if ( ev & e ) {
                a ~= _names[e];
            }
        }
    }
    return a.join("|");
}

class NotFoundException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

//final class FileDescriptor {
//    package {
//        immutable int   _fileno;
//        HandlerDelegate _handler;
//        AppEvent        _polling;
//    }
//    this(int fileno) nothrow @safe {
//        _fileno = fileno;
//    }
//    override string toString() const @safe {
//        import std.format: format;
//        return appeventToString(_polling);
//        //return "FileDescriptor: filehandle: %d, events: %s".format(_fileno, appeventToString(_polling));
//    }
//}

class CanPoll {
    union Id {
        int     fd;
    }
    Id  id;
}

final class Timer : CanPoll {
    private static ulong timer_id = 1;
    package {
        immutable ulong           _id;
        immutable SysTime         _expires;
        immutable HandlerDelegate _handler;
        immutable string          _file;
        immutable int             _line;
    }
    int opCmp(in Timer other) const nothrow pure @safe {
        int timeCmp = _expires.opCmp(other._expires);
        if ( timeCmp != 0 ) {
            return timeCmp;
        }
        return _id < other._id ? -1 : 1;
    }

    bool eq(const Timer b) const pure nothrow @safe {
        return this._id == b._id && this._expires == b._expires && this._handler == b._handler;
    }
    
    this(Duration d, HandlerDelegate h, string f = __FILE__, int l =  __LINE__) @safe {
        _expires = Clock.currTime + d;
        _handler = h;
        _id = timer_id;
        _file = f;
        _line = l;
        timer_id++;
    }
    this(SysTime e, HandlerDelegate h, string f = __FILE__, int l =  __LINE__) @safe {
        enforce(e != SysTime.init, "Unintialized expires for new timer");
        enforce(h != HandlerDelegate.init, "Unitialized handler for new Timer");
        _expires = e;
        _handler = h;
        _file = f;
        _line = l;
        _id = timer_id++;
    }
    override string toString() const @trusted {
        import std.format: format;
        return "timer: expires: %s, id: %d, addr %X (%s:%d)".format(_expires, _id, cast(void*)this, _file, _line);
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
    override string toString() const @trusted {
        import std.format: format;
        return "signal: signum: %d, id: %d".format(_signum, _id);
    }
}

struct IORequest {
    size_t              to_read = 0;
    immutable           allowPartialInput = true;
    immutable(ubyte)[]  output;

    void delegate(IOResult) @safe callback;
}

struct IOResult {
    immutable(ubyte)[]  input;      // what we received
    immutable(ubyte)[]  output;     // updated output slice
    bool                timedout;   // if we timedout
    bool                error;      // if there was an error
}