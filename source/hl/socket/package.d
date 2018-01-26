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
import nbuff;

//alias Socket = RefCounted!SocketImpl;

alias AcceptFunction = void function(Socket);
alias AcceptDelegate = void delegate(Socket);

static ~this() {
    trace("deinit");
}

Socket[int] fd2so;

void loopCallback(int fd, AppEvent ev) {
    debug tracef("loopCallback for %d", fd);
    Socket s = fd2so[fd];
    if ( s && s._fileno >= 0) {
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

class Socket {
    private {
        immutable ubyte _af = AF_INET;
        immutable int   _sock_type = SOCK_STREAM;
        int             _fileno = -1;
        HandlerDelegate _handler;
        AppEvent        _polling = AppEvent.NONE;
        size_t          _buffer_size = 16*1024;
    }

    this(ubyte af = AF_INET, int sock_type = SOCK_STREAM) {
        _af = af;
        _sock_type = sock_type;
    }

    this(ubyte af, int sock_type, int s)
    in {assert(s>=0);}
    body {
        this._af = af;
        this._sock_type = sock_type;
        this._fileno = s;
        auto flags = fcntl(_fileno, F_GETFL, 0) | O_NONBLOCK;
        fcntl(_fileno, F_SETFL, flags);
    }


    ~this() {
        if ( _fileno != -1 ) {
            .close(_fileno);
        }
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
        auto flags = fcntl(_fileno, F_GETFL, 0) | O_NONBLOCK;
        fcntl(_fileno, F_SETFL, flags);
        return _fileno;
    }

    public void close() @safe {
        debug tracef("closing %d", _fileno);
        if ( _fileno != -1 ) {
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

    public void accept(L, F)(L loop, scope F f) {
        _handler = (scope AppEvent ev) {
            //
            // call accept until there is no more connections in the queue
            // but no more than ACCEPTS_IN_A_ROW
            //
            enum ACCEPTS_IN_A_ROW = 10;
            foreach(_; 0..ACCEPTS_IN_A_ROW) {
                sockaddr sa;
                debug tracef("Accept handler on: %d", _fileno);
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
                int flag = 1;
                auto rc = .setsockopt(new_s, IPPROTO_TCP, TCP_NODELAY, &flag, flag.sizeof);
                if ( rc != 0 ) {
                     throw new Exception(to!string(strerror(errno())));
                }
                auto flags = fcntl(new_s, F_GETFL, 0) | O_NONBLOCK;
                fcntl(new_s, F_SETFL, flags);
                Socket ns = new Socket(_af, _sock_type, new_s);
                fd2so[new_s] = ns;
                f(ns);
            }
        };
        //fd2Socket...
        _polling |= AppEvent.IN;
        loop.startPoll(_fileno, AppEvent.IN, &loopCallback);
    }

    auto io(L)(L loop, in IORequest iorq, in Duration timeout) @safe {
        IOResult result;

        size_t              to_read = iorq.to_read;
        ubyte[]             input;
        immutable(ubyte)[]  output = iorq.output;

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
            HandlerDelegate terminate = (AppEvent e) {
                debug tracef("io timedout");
                _polling ^= ev;
                loop.stopPoll(_fileno, ev);
                loop.flush();
                result.input = assumeUnique(input);
                result.output = output;
                result.timedout = true;
                iorq.callback(result);
            };
            t = new Timer(timeout, terminate);
            loop.startTimer(t);
        }
        _handler = (AppEvent ev) {
            tracef("event %s on fd %d", appeventToString(ev), _fileno);
            if ( ev & AppEvent.IN )
            {
                ubyte[] b = new ubyte[](min(_buffer_size, to_read));
                auto rc = .recv(_fileno, b.ptr, _buffer_size, 0);
                debug tracef("recv on fd %d returned %d", _fileno, rc);
                if ( rc < 0 )
                {
                    result.error = true;
                    _polling ^= pollingFor;
                    loop.stopPoll(_fileno, pollingFor);
                    loop.flush();
                    if ( t ) {
                        loop.stopTimer(t);
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
                        _polling ^= pollingFor;
                        loop.stopPoll(_fileno, pollingFor);
                        loop.flush();
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
                    _polling ^= pollingFor;
                    loop.stopPoll(_fileno, pollingFor);
                    loop.flush();
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
            if ( ev & AppEvent.OUT ) {
                debug tracef("sending %s", output);
                assert(output.length>0);
                auto rc = .send(_fileno, output.ptr, output.length, 0);
                if ( rc < 0 ) {
                    // error sending
                }
                output = output[rc..$];
                if ( output.length == 0 ) {
                    _polling ^= pollingFor;
                    loop.stopPoll(_fileno, pollingFor);
                    loop.flush();
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
            else
            {
                debug tracef("Unhandled event on %d", _fileno);
            }
        };
        loop.startPoll(_fileno, pollingFor, &loopCallback);
        return 0;
    }

    long send(immutable(ubyte)[] data) {
        return .send(_fileno, data.ptr, data.length, 0);
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

unittest {
    import core.sys.posix.arpa.inet;
    assert(str2inetaddr("0.0.0.0:1") == tuple(0, htons(1)));
    assert(str2inetaddr("1.0.0.0:0") == tuple(htonl(0x01000000),0 ));
    assert(str2inetaddr("255.255.255.255:0") == tuple(0xffffffff, 0));
}

unittest {
    globalLogLevel = LogLevel.trace;

    Socket s0;
    s0.open();
    Socket s1 = s0;
    s0.close();
    s1.close();
}

unittest {
    globalLogLevel = LogLevel.trace;

    Socket s;
    s.open();
    s.close();
}