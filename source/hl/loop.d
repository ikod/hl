module hl.loop;

import std.traits;
import std.datetime;
import std.container;
import std.exception;
import std.experimental.logger;

import hl.drivers;
import hl.events;

EventLoop!NativeEventLoopImpl     native_loop;
EventLoop!FallbackEventLoopImpl   fallback_loop;

static if ( hasMember!(NativeEventLoopImpl, "native") ) {
    alias eventLoop = native_loop;
} else {
    alias eventLoop = fallback_loop;
}

static this() {
    native_loop._impl.initialize();
    fallback_loop._impl.initialize();
}
static ~this() {
    native_loop._impl.deinit();
    fallback_loop._impl.deinit();
}

/**
  * return ref to best available (native if present or fallback otherwise) event loop driver
 **/
auto getEventLoop() {
    return &eventLoop;
}
/**
  * return ref to native event loop
 **/
auto getNativeEventLoop() {
    return &native_loop;
}

/**
  * return ref to fallback event loop
 **/
auto getFallBackEventLoop() {
    return &fallback_loop;
}

void runEventLoop(Duration d = Duration.max) {
    eventLoop.run(d);
}

struct EventLoop(I) {
    I _impl;
    void run(Duration d = Duration.max) {
        _impl.run(d);
    }
    void stop() {
        _impl.stop();
    }
    void startTimer(Timer t) {
        _impl.start_timer(t);
    }
    void stopTimer(Timer t) {
        _impl.stop_timer(t);
    }
    void startSignal(Signal s) {
        _impl.start_signal(s);
    }
    void stopSignal(Signal s) {
        _impl.stop_signal(s);
    }
    void startPoll(int fd, AppEvent ev, FileHandlerFunction f) {
        _impl.start_poll(fd, ev, f);
    }
    void stopPoll(int fd, AppEvent ev) {
        _impl.stop_poll(fd, ev);
    }
    void flush() {
        _impl.flush();
    }
}

unittest {
    import std.stdio;
    globalLogLevel = LogLevel.info;
    auto best_loop = getEventLoop();
    auto fallback_loop = getFallBackEventLoop();
    version(OSX) {
        assert(typeid(best_loop) != typeid(fallback_loop));
    }
    writefln("Native   event loop: %s", best_loop._impl._name);
    writefln("Fallback event loop: %s", fallback_loop._impl._name);
//    best_loop.run(500.msecs);
//    fallback_loop.run(500.msecs);
}

unittest {
    /**
    *
    *  Timer tests
    *
    **/
    globalLogLevel = LogLevel.info;
    info(" --- Testing timers ---");
    import std.stdio;
    int i1, i2;
    auto loop = getEventLoop();
    auto fallback_loop = getFallBackEventLoop();

    HandlerDelegate h1 = delegate void(AppEvent e) {tracef("h1 called");i1++;};
    HandlerDelegate h2 = delegate void(AppEvent e) {tracef("h2 called");i2++;};
    {
        auto now = Clock.currTime;
        Timer a = new Timer(now, h1);
        Timer b = new Timer(now, h1);
        assert(b>a);
    }
    {
        auto now = Clock.currTime;
        Timer a = new Timer(now, h1);
        Timer b = new Timer(now + 1.seconds, h1);
        assert(b>a);
    }
    {
        /** test startTimer, and then stopTimer before runLoop */
        auto now = Clock.currTime;
        i1 = i2 = 0;
        Timer a = new Timer(now + 100.msecs, h1);
        Timer b = new Timer(now + 1000.msecs, h2);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.stopTimer(b);
        loop.run(200.msecs);
        assert(i1==1);
        assert(i2==0);
        a = new Timer(100.msecs, h1);
        b = new Timer(1000.msecs, h2);
        fallback_loop.startTimer(a);
        fallback_loop.startTimer(b);
        fallback_loop.stopTimer(b);
        fallback_loop.run(200.msecs);
        assert(i1==2);
        assert(i2==0);
    }
    {
        /** stop event loop inside from timer **/
        info("stop event loop inside from timer");
        auto now = Clock.currTime;
        Timer a, b;

        i1 = 0;
        a = new Timer(10.msecs, (AppEvent e){
            loop.stop();
        });
        b = new Timer(110.msecs, h1);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.run();
        assert(i1 == 0);
        loop.stopTimer(b);

        i1 = 0;
        a = new Timer(10.msecs, (AppEvent e){
            fallback_loop.stop();
        });
        b = new Timer(110.msecs, h1);
        fallback_loop.startTimer(a);
        fallback_loop.startTimer(b);
        fallback_loop.run();
        assert(i1 == 0);
        fallback_loop.stopTimer(b);
    }
    {
        //globalLogLevel = LogLevel.trace;
        /** test timer execution order **/
        info("timer execution order");
        auto now = Clock.currTime;
        int[] seq;
        HandlerDelegate sh1 = delegate void(AppEvent e) {seq ~= 1;};
        HandlerDelegate sh2 = delegate void(AppEvent e) {seq ~= 2;};
        HandlerDelegate sh3 = delegate void(AppEvent e) {seq ~= 3;};
        assertThrown(new Timer(SysTime.init, null));
        Timer a = new Timer(now + 500.msecs, sh1);
        Timer b = new Timer(now + 500.msecs, sh2);
        Timer c = new Timer(now + 300.msecs, sh3);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.startTimer(c);
        loop.run(510.msecs);
        assert(seq == [3, 1, 2]);
        a = new Timer(500.msecs, sh1);
        b = new Timer(500.msecs, sh2);
        c = new Timer(300.msecs, sh3);
        fallback_loop.startTimer(a);
        fallback_loop.startTimer(b);
        fallback_loop.startTimer(c);
        fallback_loop.run(510.msecs);
        assert(seq == [3, 1, 2, 3, 1 ,2]);
    }
    {
        /** test exception handling in timer **/
        info("exception handling in timer");
        HandlerDelegate throws = delegate void(AppEvent e){throw new Exception("test exception");};
        Timer a = new Timer(50.msecs, throws);
        loop.startTimer(a);
        auto logLevel = globalLogLevel;
        globalLogLevel = LogLevel.fatal;
        loop.run(100.msecs);
        globalLogLevel = logLevel;
        a = new Timer(50.msecs, throws);
        fallback_loop.startTimer(a);
        globalLogLevel = LogLevel.fatal;
        fallback_loop.run(100.msecs);
        globalLogLevel = logLevel;
    }
    {
        /** test stop timer inside from handler **/
        info("stop timer inside from timer handler");
        Timer a;
        HandlerDelegate h = delegate void(AppEvent e) {
            loop.stopTimer(a);
            a = null;
        };
        a = new Timer(50.msecs, h);
        loop.startTimer(a);
        auto logLevel = globalLogLevel;
        globalLogLevel = LogLevel.fatal;
        loop.run(100.msecs);
        globalLogLevel = logLevel;
        a = new Timer(50.msecs, h);
        fallback_loop.startTimer(a);
        globalLogLevel = LogLevel.fatal;
        fallback_loop.run(100.msecs);
        globalLogLevel = logLevel;
    }
    {
        /** overdue timers handling **/
        info("test overdue timers handling");
        import core.thread;
        int[]   seq;
        auto    slow = delegate void(AppEvent e) {Thread.sleep(20.msecs); seq ~= 1;};
        auto    fast = delegate void(AppEvent e) {seq ~= 2;};
        Timer a = new Timer(50.msecs, slow);
        Timer b = new Timer(60.msecs, fast);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.run(100.msecs);
        assert(seq == [1,2]);
        a = new Timer(50.msecs, slow);
        b = new Timer(60.msecs, fast);
        fallback_loop.startTimer(a);
        fallback_loop.startTimer(b);
        fallback_loop.run(100.msecs);
        assert(seq == [1, 2, 1, 2]);

        a = new Timer(-5.seconds, fast);
        loop.startTimer(a);
        loop.run(0.seconds);

        a = new Timer(-5.seconds, fast);
        fallback_loop.startTimer(a);
        fallback_loop.run(0.seconds);
        assert(seq == [1,2,1,2,2,2]);

        //globalLogLevel = LogLevel.trace;
        seq = new int[](0);
        /** test setting overdue timer inside from overdue timer **/
        auto set_next = delegate void(AppEvent e) {
            b = new Timer(-10.seconds, fast);
            loop.startTimer(b);
        };
        a = new Timer(-5.seconds, set_next);
        loop.startTimer(a);
        loop.run(10.msecs);
        assert(seq == [2]);

        set_next = delegate void(AppEvent e) {
            b = new Timer(-10.seconds, fast);
            fallback_loop.startTimer(b);
        };
        a = new Timer(-5.seconds, set_next);
        fallback_loop.startTimer(a);
        fallback_loop.run(10.msecs);
        assert(seq == [2,2]);

        seq = new int[](0);
        /** test setting overdue timer inside from normal timer **/
        set_next = delegate void(AppEvent e) {
            b = new Timer(-10.seconds, fast);
            loop.startTimer(b);
        };
        a = new Timer(50.msecs, set_next);
        loop.startTimer(a);
        loop.run(60.msecs);
        assert(seq == [2]);

        set_next = delegate void(AppEvent e) {
            b = new Timer(-10.seconds, fast);
            fallback_loop.startTimer(b);
        };
        a = new Timer(50.msecs, set_next);
        fallback_loop.startTimer(a);
        fallback_loop.run(60.msecs);
        assert(seq == [2,2]);
    }
    {
        import core.thread;
        /** test pending timer events **/
        info("test pending timer events");
        i1 = 0;
        auto a = new Timer(50.msecs, h1);
        loop.startTimer(a);
        loop.run(10.msecs);
        assert(i1==0);
        Thread.sleep(45.msecs);
        loop.run(0.seconds);
        assert(i1==1);

        i1 = 0;
        a = new Timer(50.msecs, h1);
        fallback_loop.startTimer(a);
        fallback_loop.run(10.msecs);
        assert(i1==0);
        Thread.sleep(45.msecs);
        fallback_loop.run(0.seconds);
        assert(i1==1);
    }
}

unittest {
    /**
     *
     * Signal tests
     *
    **/
    import std.stdio;
    import core.sys.posix.signal;

    info("--- Testing signals ---");
    auto loop = getEventLoop();
    auto fallback_loop = getFallBackEventLoop();
    globalLogLevel = LogLevel.info;
    int i1, i2;
    SigHandlerDelegate h1 = delegate void(int signum) {
        i1++;
    };
    SigHandlerDelegate h2 = delegate void(int signum) {
        i2++;
    };
    {
        auto sighup1 = new Signal(SIGHUP, h1);
        auto sighup2 = new Signal(SIGHUP, h2);
        auto sigint = new Signal(SIGINT, h2);
        loop.startSignal(sighup1);
        loop.startSignal(sighup2);
        loop.startSignal(sigint);
        loop.stopSignal(sighup1);
        loop.stopSignal(sighup2);
        loop.stopSignal(sigint);
        loop.run(300.msecs);
    }
    version(Posix) {
        import core.sys.posix.unistd;
        import core.sys.posix.sys.wait;
        import core.thread;
        info("testing posix signals with native driver");
        globalLogLevel = LogLevel.info;
        i1 = i2 = 0;
        auto sighup1 = new Signal(SIGHUP, h1);
        auto sighup2 = new Signal(SIGHUP, h2);
        auto sigint1 = new Signal(SIGINT, h2);
        foreach(s; [sighup1, sighup2, sigint1]) {
            loop.startSignal(s);
        }
        auto parent_pid = getpid();
        auto child_pid = fork();
        if ( child_pid == 0 ) {
            Thread.sleep(500.msecs);
            kill(parent_pid, SIGHUP);
            kill(parent_pid, SIGINT);
            _exit(0);
        } else {
            loop.run(1.seconds);
            waitpid(child_pid, null, 0);
        }
        assert(i1 == 1);
        assert(i2 == 2);
        foreach(s; [sighup1, sighup2, sigint1]) {
            loop.stopSignal(s);
        }
        loop.run(1.msecs); // send stopSignals to kernel

        info("testing posix signals with fallback driver");
        globalLogLevel = LogLevel.info;
        i1 = i2 = 0;
        foreach(s; [sighup1, sighup2, sigint1]) {
            fallback_loop.startSignal(s);
        }
        child_pid = fork();
        if ( child_pid == 0 ) {
            Thread.sleep(500.msecs);
            kill(parent_pid, SIGHUP);
            kill(parent_pid, SIGINT);
            _exit(0);
        } else {
            fallback_loop.run(1.seconds);
            waitpid(child_pid, null, 0);
        }
        assert(i1 == 1);
        assert(i2 == 2);
        foreach(s; [sighup1, sighup2, sigint1]) {
            fallback_loop.stopSignal(s);
        }
        fallback_loop.run(1.msecs); // send stopSignals to kernel
    }
}

unittest {
    globalLogLevel = LogLevel.info;
    info(" --- Testing sockets ---");
    import hl.socket: Socket;
    auto loop = getEventLoop();
    auto server = new Socket();
    auto fd = server.open();
    //server.close();
    assert(fd >= 0);
    assertThrown!Exception(server.bind("a:b:c"));
    void function(Socket) f = (Socket s) {
        tracef("accepted", s);
        s.close();
    };
    server.bind("127.0.0.1:16000");
    server.listen();
    server.accept(loop, f);
    loop.run(50.seconds);

    //globalLogLevel = LogLevel.trace;
    //auto fallback_loop = getFallBackEventLoop();
    //server = Socket();
    //server.open();
    //server.bind("127.0.0.1:16000");
    //server.listen();
    //server.accept(fallback_loop, f);
    //fallback_loop.startPoll(server.descriptor(), AppEvent.IN);
    //fallback_loop.run(100.seconds);
}