module hl.events;

import std.datetime;
import std.exception;
import std.container;

//import nbuff;

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
alias NotificationHandler = void delegate(Notification) @safe;

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

//class CanPoll {
//    union Id {
//        int     fd = -1;
//    }
//    Id  id;
//}

abstract class EventHandler {
    abstract void eventHandler(AppEvent) @safe;
}

final class Timer {
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

final class Signal {
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
    bool                allowPartialInput = true;
    immutable(ubyte)[]  output;

    void delegate(IOResult) @safe callback;

}

struct IOResult {
    immutable(ubyte)[]  input;      // what we received
    immutable(ubyte)[]  output;     // updated output slice
    bool                timedout;   // if we timedout
    bool                error;      // if there was an error
    string toString() const @trusted {
        import std.format;
        return "in:[%(%02X %)], out:[%(%02X %)], tmo: %s, error: %s".format(input, output, timedout?"yes":"no", error?"yes":"no");
    }
}

struct CircBuff(T) {
    enum Size = 512;
    private
    {
        ushort start=0, length = 0;
        T[Size] queue;
    }

    invariant
    {
        assert(length<=Size);
        assert(start<Size);
    }

    auto get() @safe
    in
    {
        assert(!empty);
    }
    out
    {
        assert(!full);
    }
    do
    {
        enforce(!empty);
        auto v = queue[start];
        length--;
        start = (++start) % Size;
        return v;
    }

    void put(Notification ue) @safe
    in
    {
        assert(!full);
    }
    out
    {
        assert(!empty);
    }
    do
    {
        enforce(!full);
        queue[(start + length)%Size] = ue;
        length++;
    }
    bool empty() const @safe @property @nogc nothrow {
        return length == 0;
    }
    bool full() const @safe @property @nogc nothrow {
        return length == Size;
    }
}

class Notification {
    import containers;
    private SList!(void delegate(Notification) @safe) _subscribers;

    void handler() @safe {
        foreach(s; _subscribers) {
            s(this);
        }
    }

    void subscribe(void delegate(Notification) @safe s) @safe @nogc nothrow {
        _subscribers ~= s;
    }

    void unsubscribe(void delegate(Notification) @safe s) @safe @nogc {
        _subscribers.remove(s);        
    }
}


@safe unittest {
    import std.stdio;
    class TestNotification : Notification {
        int _v;
        this(int v) {
            _v = v;
        }
    }
    
    auto ueq = CircBuff!Notification();
    assert(ueq.empty);
    assert(!ueq.full);
    foreach(i;0..ueq.Size) {
        auto ue = new TestNotification(i);
        ueq.put(ue);
    }
    assert(ueq.full);
    foreach(n;0..ueq.Size) {
        auto i = ueq.get();
        assert(n==(cast(TestNotification)i)._v);
    }
    assert(ueq.empty);
    foreach(i;0..ueq.Size) {
        auto ue = new TestNotification(i);
        ueq.put(ue);
    }
    assert(ueq.full);
    foreach(n;0..ueq.Size) {
        auto i = ueq.get();
        assert(n==(cast(TestNotification)i)._v);
    }
    //
    int testvar;
    void d1(Notification n) @safe {
        testvar++;
        auto v = cast(TestNotification)n;
    }
    void d2(Notification n) {
        testvar--;
    }
    auto n1 = new TestNotification(1);
    n1.subscribe(&d1);
    n1.subscribe(&d2);
    n1.subscribe(&d1);
    n1.handler();
    assert(testvar==1);
    n1.unsubscribe(&d2);
    n1.handler();
    assert(testvar==3);
}
