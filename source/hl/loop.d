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
}

unittest {
    import std.stdio;
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
        auto now = Clock.currTime;
        i1 = i2 = 0;
        Timer a = new Timer(now + 100.msecs, h1);
        Timer b = new Timer(now + 1000.msecs, h2);
        fallback_loop.startTimer(a);
        fallback_loop.startTimer(b);
        fallback_loop.stopTimer(b);
        fallback_loop.run(1500.msecs);
        assert(i1==1);
        assert(i2==0);
    }
    {
        auto now = Clock.currTime;
        i1 = i2 = 0;
        Timer a = new Timer(now + 100.msecs, h1);
        Timer b = new Timer(now + 1000.msecs, h2);
        loop.startTimer(a);
        loop.startTimer(b);
        loop.stopTimer(b);
        loop.run(1500.msecs);
        assert(i1==1);
        assert(i2==0);
        a = new Timer(100.msecs, h1);
        b = new Timer(1000.msecs, h2);
        fallback_loop.startTimer(a);
        fallback_loop.startTimer(b);
        fallback_loop.stopTimer(b);
        fallback_loop.run(1500.msecs);
        assert(i1==2);
        assert(i2==0);
    }
    {
        auto now = Clock.currTime;
        Timer a = new Timer(now + 500.msecs, (AppEvent e){
            fallback_loop.stop();
        });
        fallback_loop.startTimer(a);
        fallback_loop.run();
    }
    {
        trace("test order");
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
}