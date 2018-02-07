module hl.socket;

import std.typecons;
import std.string;
import std.conv;
import std.traits;
import std.datetime;
import std.exception;

import std.algorithm.comparison: min;

import std.experimental.logger;

import core.memory: pureMalloc, pureFree, GC;
import core.exception : onOutOfMemoryError;

import std.experimental.allocator;
import std.experimental.allocator.building_blocks;

static import std.socket;

import core.sys.posix.sys.socket;
import core.sys.posix.unistd;
import core.sys.posix.arpa.inet;
import core.sys.posix.netinet.tcp;
import core.sys.posix.netinet.in_;

import core.sys.posix.fcntl;

import core.stdc.string;
import core.stdc.errno;

import hl.events;
import hl.common;
import nbuff;

import hl;

//alias Socket = RefCounted!SocketImpl;

alias AcceptFunction = void function(hlSocket);
alias AcceptDelegate = void delegate(hlSocket);

static ~this() {
    trace("deinit");
}

hlSocket[int] fd2so;

void loopCallback(int fd, AppEvent ev) @safe {
    debug tracef("loopCallback for %d", fd);
    hlSocket s = fd2so[fd];
    if ( s && s._fileno >= 0) {
        debug tracef("calling handler(%s) for %s", appeventToString(ev), s);
        s._handler(ev);
    } else {
        infof("impossible event %s on fd: %d", appeventToString(ev), fd);
    }
}

class SocketException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
        super(msg, file, line);
    }
}

class hlSocket {
    private {
        immutable ubyte      _af = AF_INET;
        immutable int        _sock_type = SOCK_STREAM;
        int                  _fileno = -1;
        HandlerDelegate      _handler;
        AppEvent             _polling = AppEvent.NONE;
        size_t               _buffer_size = 16*1024;
        hlEvLoop             _loop;
        immutable string     _file;
        immutable int        _line;
    }

    this(ubyte af = AF_INET, int sock_type = SOCK_STREAM, string f = __FILE__, int l =  __LINE__) @safe {
        debug tracef("create socket");
        _af = af;
        _sock_type = sock_type;
        _file = f;
        _line = l;
    }

    this(ubyte af, int sock_type, int s, string f = __FILE__, int l =  __LINE__)
    in {assert(s>=0);}
    body {
        _af = af;
        _sock_type = sock_type;
        _fileno = s;
        _file = f;
        _line = l;
        auto flags = fcntl(_fileno, F_GETFL, 0) | O_NONBLOCK;
        fcntl(_fileno, F_SETFL, flags);
    }


    ~this() {
        if ( _fileno != -1 ) {
            .close(_fileno);
        }
    }
    
    override string toString() const @safe {
        import std.format: format;
        return "socket: fileno: %d, (%s:%d)".format(_fileno, _file, _line);
    }

    public auto fileno() const pure @safe nothrow {
        return _fileno;
    }

    public int open() @trusted {
        immutable flag = 1;
        if (_fileno != -1) {
            throw new SocketException("You can't open already opened socket: fileno(%d)".format(_fileno));
        }
        _fileno = socket(_af, _sock_type, 0);
        if ( _fileno < 0 )
            return _fileno;
        _polling = AppEvent.NONE;
        fd2so[_fileno] = this;
        auto rc = .setsockopt(_fileno, IPPROTO_TCP, TCP_NODELAY, &flag, flag.sizeof);
        if ( rc != 0 ) {
             throw new Exception(to!string(strerror(errno())));
        }
        version(OSX) {
            rc = .setsockopt(_fileno, SOL_SOCKET, SO_NOSIGPIPE, &flag, flag.sizeof);
            if ( rc != 0 ) {
                 throw new Exception(to!string(strerror(errno())));
            }
        }
        auto flags = fcntl(_fileno, F_GETFL, 0) | O_NONBLOCK;
        fcntl(_fileno, F_SETFL, flags);
        return _fileno;
    }

    public void close() @safe {
        if ( _fileno != -1 ) {
            debug tracef("closing %d", _fileno);
            if ( _loop && _polling != AppEvent.NONE ) {
                debug tracef("detach from polling for %s", appeventToString(_polling));
                _loop.stopPoll(_fileno, _polling);
            }
            fd2so[_fileno] = null;
            .close(_fileno);
            _fileno = -1;
        }
    }
    
    public void bind(string addr) @trusted {
         debug {
             tracef("binding to %s", addr);
         }
         switch (_af) {
             case AF_INET:
                 {
                     import core.sys.posix.netinet.in_;
                     // addr must be "host:port"
                     auto internet_addr = str2inetaddr(addr);
                     sockaddr_in sin;
                     sin.sin_family = _af;
                     sin.sin_port = internet_addr[1];
                     sin.sin_addr = in_addr(internet_addr[0]);
                     int flag = 1;
                     auto rc = .setsockopt(_fileno, SOL_SOCKET, SO_REUSEADDR, &flag, flag.sizeof);
                     if ( rc != 0 ) {
                         throw new Exception(to!string(strerror(errno())));
                     }
                     rc = .bind(_fileno, cast(sockaddr*)&sin, cast(uint)sin.sizeof);
                     debug {
                         tracef("bind result: %d", rc);
                     }
                     if ( rc != 0 ) {
                         throw new Exception(to!string(strerror(errno())));
                     }
                 }
                 break;
             case AF_UNIX:
             default:
                 throw new Exception("unsupported address family");
         }
    }

    public void listen(int backlog = 10) @trusted {
        int rc = .listen(_fileno, backlog);
        if ( rc != 0 ) {
            throw new SocketException(to!string(strerror(errno())));
        }
    }

    public void stopPolling(L)(L loop) @safe {
        debug tracef("Stop polling on %d", _fileno);
        loop.stopPoll(_fileno, _polling);
    }

    public void connect(F)(string addr, hlEvLoop loop, scope F f, Duration timeout) @safe {
         switch (_af) {
             case AF_INET:
                 {
                     import core.sys.posix.netinet.in_;
                     // addr must be "host:port"
                     auto internet_addr = str2inetaddr(addr);
                     sockaddr_in sin;
                     sin.sin_family = _af;
                     sin.sin_port = internet_addr[1];
                     sin.sin_addr = in_addr(internet_addr[0]);
                     uint sa_len = sin.sizeof;
                     auto rc = (() @trusted => .connect(_fileno, cast(sockaddr*)&sin, sa_len))();
                     if ( rc == -1 && errno() != EINPROGRESS ) {
                        debug tracef("connect errno: %s", s_strerror(errno()));
                        f(AppEvent.ERR);
                        return;
                     }
                     _handler = (AppEvent ev) {
                        debug tracef("connection event: %s", appeventToString(ev));
                        _polling = AppEvent.NONE;
                        loop.stopPoll(_fileno, AppEvent.OUT);
                        f(ev);
                     };
                    _polling |= AppEvent.OUT;
                    loop.startPoll(_fileno, AppEvent.OUT, &loopCallback);
                 }
                 break;
             default:
                 throw new Exception("unsupported address family");
        }
    }

    public void accept(F)(hlEvLoop loop, scope F f) {
        _handler = (scope AppEvent ev) @trusted {
            //
            // call accept until there is no more connections in the queue
            // but no more than ACCEPTS_IN_A_ROW
            //
            enum ACCEPTS_IN_A_ROW = 10;
            foreach(_; 0..ACCEPTS_IN_A_ROW) {
                sockaddr sa;
                uint sa_len = sa.sizeof;
                int new_s = .accept(_fileno, &sa, &sa_len);
                if ( new_s == -1 ) {
                    auto err = errno();
                    if ( err == EWOULDBLOCK || err == EAGAIN ) {
                        // POSIX.1-2001 and POSIX.1-2008 allow
                        // either error to be returned for this case, and do not require
                        // these constants to have the same value, so a portable
                        // application should check for both possibilities.
                        break;
                    }
                    throw new Exception(to!string(strerror(err)));
                }
                debug tracef("New socket fd: %d", new_s);
                immutable int flag = 1;
                auto rc = .setsockopt(new_s, IPPROTO_TCP, TCP_NODELAY, &flag, flag.sizeof);
                if ( rc != 0 ) {
                     throw new Exception(to!string(strerror(errno())));
                }
                version(OSX) {
                    rc = .setsockopt(_fileno, SOL_SOCKET, SO_NOSIGPIPE, &flag, flag.sizeof);
                    if ( rc != 0 ) {
                         throw new Exception(to!string(strerror(errno())));
                    }
                }
                auto flags = fcntl(new_s, F_GETFL, 0) | O_NONBLOCK;
                fcntl(new_s, F_SETFL, flags);
                hlSocket ns = new hlSocket(_af, _sock_type, new_s);
                fd2so[new_s] = ns;
                f(ns);
            }
        };
        //fd2Socket...
        _polling |= AppEvent.IN;
        loop.startPoll(_fileno, AppEvent.IN, &loopCallback);
    }

    auto io(hlEvLoop loop, in IORequest iorq, in Duration timeout) @safe {
        IOResult result;

        size_t              to_read = iorq.to_read;
        ubyte[]             input;
        immutable(ubyte)[]  output = iorq.output;

        _loop = loop;
        Timer t;

        AppEvent ev = AppEvent.NONE;
        if ( iorq.output && iorq.output.length ) {
            ev |= AppEvent.OUT;
        }
        if ( to_read > 0 ) {
            ev |= AppEvent.IN;
            input.reserve(to_read);
        }
        immutable pollingFor = ev;
        assert(pollingFor != AppEvent.NONE);

        if ( timeout > 0.seconds ) {
            HandlerDelegate terminate = (AppEvent e) @safe {
                debug tracef("io timedout");
                loop.stopPoll(_fileno, ev);
                _polling = AppEvent.NONE;
                delegate void() @trusted {
                    result.input = assumeUnique(input);
                }();
                result.output = output;
                result.timedout = true;
                iorq.callback(result);
            };
            t = new Timer(timeout, terminate);
            loop.startTimer(t);
        }
        _handler = (AppEvent ev) @trusted {
            debug tracef("event %s on fd %d", appeventToString(ev), _fileno);
            if ( ev & AppEvent.IN )
            {
                ubyte[] b = new ubyte[](min(_buffer_size, to_read));
                auto rc = .recv(_fileno, &b[0], _buffer_size, 0);
                debug tracef("recv on fd %d returned %d", _fileno, rc);
                if ( rc < 0 )
                {
                    result.error = true;
                    _polling &= pollingFor ^ AppEvent.ALL;
                    _loop.stopPoll(_fileno, pollingFor);
                    if ( t ) {
                        _loop.stopTimer(t);
                        t = null;
                    }
                    result.input = assumeUnique(input);
                    result.output = output;
                    iorq.callback(result);
                    return;
                }
                if ( rc > 0 )
                {
                    debug tracef("adding data %s", b[0..rc]);
                    input ~= b[0..rc];
                    b = null;
                    to_read -= rc;
                    if ( to_read == 0 || iorq.allowPartialInput ) {
                        loop.stopPoll(_fileno, pollingFor);
                        _polling = AppEvent.NONE;
                        if ( t ) {
                            loop.stopTimer(t);
                            t = null;
                        }
                        result.input = assumeUnique(input);
                        result.output = output;
                        iorq.callback(result);
                        return;
                    }
                }
                if ( rc == 0 )
                {
                    // socket closed
                    loop.stopPoll(_fileno, pollingFor);
                    if ( t ) {
                        loop.stopTimer(t);
                        t = null;
                    }
                    result.input = assumeUnique(input);
                    result.output = output;
                    _polling = AppEvent.NONE;
                    iorq.callback(result);
                    return;
                }
            }
            if ( ev & AppEvent.OUT ) {
                debug tracef("sending %s", output);
                assert(output.length>0);
                uint flags = 0;
                version(linux) {
                    flags = MSG_NOSIGNAL;
                }
                auto rc = .send(_fileno, &output[0], output.length, flags);
                if ( rc < 0 ) {
                    // error sending
                }
                output = output[rc..$];
                if ( output.length == 0 ) {
                    loop.stopPoll(_fileno, pollingFor);
                    if ( t ) {
                        loop.stopTimer(t);
                        t = null;
                    }
                    result.input = assumeUnique(input);
                    result.output = output;
                    _polling = AppEvent.NONE;
                    iorq.callback(result);
                    return;
                }
            }
            else
            {
                debug tracef("Unhandled event on %d", _fileno);
            }
        };
        loop.startPoll(_fileno, pollingFor, &loopCallback);
        return 0;
    }

    long send(immutable(ubyte)[] data) @trusted {
        return .send(_fileno, data.ptr, data.length, 0);
    }
    void send(immutable(ubyte)[] data, Duration timeout) {
    
    }
}


private auto str2inetaddr(string addr) @safe pure {
    auto s = addr.split(":");
    if ( s.length != 2 ) {
        throw new Exception("incorrect addr %s, expect host:port", addr);
    }
    auto host = s[0].split(".");
    if ( host.length != 4 ) {
        throw new Exception("addr must be in form a.b.c.d:p");
    }
    uint   a = to!ubyte(host[0]) << 24 | to!ubyte(host[1]) << 16 | to!ubyte(host[2]) << 8 | to!ubyte(host[3]);
    ushort p = to!ushort(s[1]);
    return tuple(core.sys.posix.arpa.inet.htonl(a), core.sys.posix.arpa.inet.htons(p));
}

@safe unittest {
    import core.sys.posix.arpa.inet;
    assert(str2inetaddr("0.0.0.0:1") == tuple(0, htons(1)));
    assert(str2inetaddr("1.0.0.0:0") == tuple(htonl(0x01000000),0 ));
    assert(str2inetaddr("255.255.255.255:0") == tuple(0xffffffff, 0));
}

@safe unittest {
    globalLogLevel = LogLevel.info;

    hlSocket s0 = new hlSocket();
    s0.open();
    hlSocket s1 = s0;
    s0.close();
    s1.close();
}

@safe unittest {
    globalLogLevel = LogLevel.info;

    hlSocket s = new hlSocket();
    s.open();
    s.close();
}

//unittest {
//    globalLogLevel = LogLevel.trace;
//
//    hlSocket s = new hlSocket();
//    s.open();
//
//
//    auto mockLoop = new hlEvLoop();
//    mockLoop.run = (Duration d) {
//        s._handler(AppEvent.IN);
//    };
//
//    mockLoop.startPoll = (int fd, AppEvent ev, FileHandlerFunction f) @safe {
//        tracef("called mock startPoll: %d, %s", fd, appeventToString(ev));
//    };
//
//    mockLoop.stopPoll = (int fd, AppEvent ev) @safe {
//        tracef("called mock stopPoll: %d, %s", fd, appeventToString(ev));
//    };
//
//    IORequest iorq;
//    iorq.to_read = 1;
//    iorq.output = "abc".representation();
//    iorq.callback = (IOResult r) {
//        tracef("called mock callback: %s", r);
//    };
//    auto result = s.io(mockLoop, iorq, 1.seconds);
//    mockLoop.run(1.seconds);
//    assert(s._polling == AppEvent.NONE);
//    iorq.to_read = 0;
//    result = s.io(mockLoop, iorq, 1.seconds);
//    mockLoop.run(1.seconds);
//    assert(s._polling == AppEvent.NONE);
//    s.close();
//}