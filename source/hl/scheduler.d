module hl.scheduler;

import std.experimental.logger;

import core.thread;
import std.concurrency;
import std.datetime;
import std.format;
import std.traits;
import std.exception;
import core.sync.condition;
import std.algorithm;

//import core.stdc.string;
//import core.stdc.errno;

//static import core.sys.posix.unistd;

import hl.events;
import hl.loop;
import hl.common;

import std.stdio;


class NotReadyException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

void hlSleep(Duration d) {
    if ( d <= 0.seconds) {
        return;
    }
    Throwable throwable;
    auto tid = Fiber.getThis();
    scope callback = delegate void (AppEvent e) @trusted
    {
        throwable = tid.call(Fiber.Rethrow.no);
    };
    auto t = new Timer(d, callback);
    getDefaultLoop().startTimer(t);
    Fiber.yield();
}

struct Box(T) {
    static if (!is(T == void)) {
        T   _data;
    }
    SocketPair          _pair;
    shared(Throwable)   _exception;
    @disable this(this);
}

ReturnType!F callInThread(F, A...)(F f, A args) {
    if ( Fiber.getThis() )
        return callFromFiber(f, args);
    else
        return callFromThread(f, args);
}

ReturnType!F callFromFiber(F, A...)(F f, A args) {
    auto tid = Fiber.getThis();
    assert(tid, "You can call this function only inside from Task");

    alias R = ReturnType!F;
    enum  Void = is(ReturnType!F==void);
    enum  Nothrow = [__traits(getFunctionAttributes, f)].canFind("nothrow");
    Box!R box;
    static if (!Void){
        R   r;
    }

    // create socketpair for inter-thread signalling
    box._pair = makeSocketPair();
    scope(exit) {
        box._pair.close();
    }

    void _wrapper() {
        scope(exit)
        {
            getDefaultLoop().stop();
        }
        try {
            static if (!Void) {
                r = f(args);
                box._data = r;
            }
            else {
                f(args);
            }
        } catch(shared(Exception) e) {
            box._exception = e;
        }
    }

    shared void delegate() run = () {
        //
        // in the child thread:
        // 1. start new fiber (task over wrapper) with user supplied function
        // 2. start event loop forewer
        // 3. when eventLoop done(stopped inside from wrapper) the task will finish
        // 4. store value in box and use socketpair to send signal to caller thread
        //
        auto t = task(&_wrapper);
        t.call(Fiber.Rethrow.no);
        getDefaultLoop.run(Duration.max);
        getDefaultLoop.deinit();
        ubyte[1] b = [0];
        auto s = box._pair.write(1, b);
        assert(t.ready);
        assert(t.state == Fiber.State.TERM);
        assert(s == 1);
        trace("child thread done");
    };
    Thread child = new Thread(run).start();
    //
    // in the parent
    // add socketpair[0] to eventloop for reading and wait for data on it
    // yieldng until we receive data on the socketpair
    // on event handler - sop polling on pipe and join child thread
    //
    final class ThreadEventHandler : EventHandler {
        override void eventHandler(AppEvent e) @trusted
        {
            //
            // maybe we have to read here, but actually we need only info about data availability
            // so why read?
            //
            debug tracef("interthread signalling - read ready");
            getDefaultLoop().stopPoll(box._pair[0], AppEvent.IN);
            child.join();
            debug tracef("interthread signalling - thread joined");
            auto throwable = tid.call(Fiber.Rethrow.no);
        }
    }
    getDefaultLoop().startPoll(box._pair[0], AppEvent.IN, new ThreadEventHandler());
    Fiber.yield();
    if ( box._exception ) {
        throw box._exception;
    }
    static if (!Void) {
        debug tracef("joined, value = %s", box._data);
        return box._data;
    } else {
        debug tracef("joined");
    }
}

ReturnType!F callFromThread(F, A...)(F f, A args) {
    auto tid = Fiber.getThis();
    assert(tid is null, "You can't call this function from Task (or fiber)");

    alias R = ReturnType!F;
    enum  Void = is(ReturnType!F==void);
    enum  Nothrow = [__traits(getFunctionAttributes, f)].canFind("nothrow");
    Box!R box;
    static if (!Void){
        R   r;
    }

    void _wrapper() {
        scope(exit)
        {
            getDefaultLoop().stop();
        }
        try {
            static if (!Void){
                r = f(args);
                box._data = r;
            }
            else
            {
                //writeln("calling");
                f(args);
            }
        } catch (shared(Exception) e) {
            box._exception = e;
        }
    }

    shared void delegate() run = () {
        //
        // in the child thread:
        // 1. start new fiber (task over wrapper) with user supplied function
        // 2. start event loop forewer
        // 3. when eventLoop done(stopped inside from wrapper) the task will finish
        // 4. store value in box and use socketpair to send signal to caller thread
        //
        auto t = task(&_wrapper);
        t.call(Fiber.Rethrow.no);
        getDefaultLoop.run(Duration.max);
        getDefaultLoop.deinit();
        assert(t.ready);
        assert(t.state == Fiber.State.TERM);
        trace("child thread done");
    };
    Thread child = new Thread(run).start();
    child.join();
    if ( box._exception ) {
        throw box._exception;
    }
    static if (!Void) {
        debug tracef("joined, value = %s", box._data);
        return box._data;
    } else {
        debug tracef("joined");
    }
}

//ReturnType!F spawnTask1(F, A...)(F f, A args) {
//    alias R = ReturnType!F;
//    enum  Void = is(ReturnType!F==void);
//    enum  Nothrow = [__traits(getFunctionAttributes, f)].canFind("nothrow");
//    enforce(Fiber.getThis is null, "You can't call spawnTask inside from Task. Use ...");
//    void  _wrapper() {
//        scope(exit)
//        {
//            getDefaultLoop().stop();
//        }
//        Tid owner = ownerTid();
//        static if (Nothrow) {
//            static if (!Void) 
//            {
//                R r = f(args);
//                tracef("sending %s", r);
//                owner.send(r);
//                tracef("sending %s - done", r);
//            }
//            else
//            {
//                f(args);
//                owner.send(null);
//            }
//        }
//        else {
//            try {
//                static if (!Void) 
//                {
//                    R r = f(args);
//                    tracef("sending %s", r);
//                    owner.send(r);
//                    tracef("sending %s - done", r);
//                }
//                else
//                {
//                    f(args);
//                    owner.send(null);
//                }
//            }
//            catch (shared(Exception) _e)
//            {
//                owner.send(_e);
//            }
//        }
//    }
//    shared void delegate() run = () {
//        auto t = task(&_wrapper);
//        t.call(Fiber.Rethrow.no);
//        getDefaultLoop.run(Duration.max);
//        assert(t.ready);
//        assert(t.state == Fiber.State.TERM);
//        trace("run delegate done");
//    };
//    Tid child = spawn(run);
//    static if (!Void) {
//        R _r;
//        tracef("Receiving value started");
//        receive(
//            (R r) {writefln("got res %s", r); _r = r;},
//            (shared(Exception) e) {tracef("got exception"); throw e;},
//            (Variant any) {writefln("got variant %s", any);}
//        );
//        tracef("Receiving done");
//        return _r;
//    } else {
//        receive(
//            (shared(Exception) e) {tracef("got exception"); throw e;},
//            (Variant any) {writefln("got variant %s", any); assert(any == null);}
//        );
//        return;
//    }
//    assert(0, "This should not happen");
//}
//
///
/// spawn thread,
/// in child: 
///  call fiber task
///  start eventLoop, run it forewer or until duration expired
///  send() to parent result(if available) or Exception
///
auto spawnTask(T)(T task, Duration howLong = Duration.max) {
    shared void delegate() run = () {
        Throwable throwable = task.call(Fiber.Rethrow.no);
        getDefaultLoop.run(howLong);
        assert(task.ready);
        assert(task.state == Fiber.State.TERM);

        Tid owner = ownerTid();
        if ( throwable is null )
        {
            static if (!task.Void) {
                debug tracef("sending result %s", task.result);
                owner.send(task.result);
            }
            else
            {
                // have to send something as user code must wait for anything for non-daemons
                debug tracef("sending null");
                owner.send(null);
            }
        }
        else
        {
            immutable e = new Exception(throwable.msg);
            try
            {
                debug tracef("sending exception");
                owner.send(e);
            } catch (Exception ee)
            {
                errorf("Exception %s when sending exception %s", ee, e);
            }
        }
        task.reset();
        getDefaultLoop.deinit();
        debug tracef("task thread finished");
    };
    auto tid = spawn(run);
    return tid;
}

class Task(F, A...) : Fiber if (isCallable!F) {
    enum  Void = is(ReturnType!F==void);
    alias start = call;
    private {
        alias R = ReturnType!F;

        F            _f;
        A            _args;
        bool         _ready;
        Notification _done;
        Throwable    _exception;

        static if ( !Void ) {
            R       _result;
        }
    }

    ///
    /// wait() - wait forewer
    /// wait(Duration) - wait with timeout
    /// 
    bool wait(T...)(T args) if (T.length <= 1) {
        //if ( state == Fiber.State.TERM )
        //{
        //    throw new Exception("You can't wait on finished task");
        //}
        if ( _ready )
        {
            if ( _exception !is null ) {
                throw _exception;
            }
            return true;
        }
        static if (T.length == 1) {
            Duration timeout = args[0];
            if ( timeout <= 0.msecs )
            {
                if ( _exception !is null ) {
                    throw _exception;
                }
                return _ready;
            }
        } else {
            Duration timeout = 0.msecs;
        }
        auto current = Fiber.getThis;
        assert(current !is null, "You can wait task only from another task or fiber");
        if ( _done is null ) {
            _done = new Notification();
        }
        auto _handler = (Notification n) @trusted {
            current.call();
        };
        _done.subscribe(_handler);
        Timer t;
        if ( timeout > 0.msecs ) {
            t = new Timer(timeout, (AppEvent e) @trusted {
                _done.unsubscribe(_handler);
                current.call();
            });
            getDefaultLoop().startTimer(t);
        }
        Fiber.yield();
        if ( t )
        {
            getDefaultLoop().stopTimer(t);
        }
        if ( _exception !is null ) {
            throw _exception;
        }
        return _ready;
    }

    static if (!Void) {
        auto waitResult() {
            wait();
            enforce(_ready);
            return _result;
        }
    }

    @property
    final bool ready() const {
        pragma(inline, true)
        return _ready;
    }
    static if (!Void) {
        @property
        final auto result() const {
            enforce!NotReadyException(_ready, "You can't get result from not ready task");
            return _result;
        }
    }
    final this(F f, A args) {
        _f = f;
        _args = args;
        super(&run);
    }
    private final void run() {
        scope(exit)
        {
            _ready = true;
            // here we call() all suspended fibers
            // current fiber will terminate only when we return from all these calls
            if ( _done !is null ) {
                getDefaultLoop().postNotification(_done);
            }
        }
        static if ( Void )
        {
            try {
                _f(_args);
            } catch (Exception e) {
                _exception = e;
            }
        }
        else 
        {
            try {
                _result = _f(_args);
            } catch(Exception e) {
                _exception = e;
            }
        } 
    }
}

auto task(F, A...)(F f, A a) {
    return new Task!(F,A)(f, a);
}

unittest {
    int i;
    int f(int s) {
        i+=s;
        return(i);
    }
    auto t = task(&f, 1);
    t.call();
    assert(i==1, "i=%d, expected 1".format(i));
    assert(t.result == 1, "result: %d, expected 1".format(t.result));
}

//class MyScheduler : Scheduler {
//    /**
//     * This simply runs op directly, since no real scheduling is needed by
//     * this approach.
//     */
//    void start(void delegate() op)
//    {
//        op();
//    }
//
//    /**
//     * Creates a new kernel thread and assigns it to run the supplied op.
//     */
//    void spawn(void delegate() op)
//    {
//        //try{writefln("spawn %s", thisInfo.owner);}catch(Exception e){}
//        auto t = new Thread(op);
//        t.start();
//    }
//
//    /**
//     * This scheduler does no explicit multiplexing, so this is a no-op.
//     */
//    void yield() nothrow
//    {
//        try{writefln("yield %s", thisInfo.owner);}catch(Exception e){}
//        auto f = Fiber.getThis();
//        if ( f is null ) {
//            return;
//        }
//        //f.yield();
//    }
//
//    /**
//     * Returns ThreadInfo.thisInfo, since it is a thread-local instance of
//     * ThreadInfo, which is the correct behavior for this scheduler.
//     */
//    @property ref ThreadInfo thisInfo() nothrow
//    {
//        return ThreadInfo.thisInfo;
//    }
//
//    /**
//     * Creates a new Condition variable.  No custom behavior is needed here.
//     */
//    Condition newCondition(Mutex m) nothrow
//    {
//        return new Condition(m);
//    }
//    private {
//    }
//}

unittest {
    globalLogLevel = LogLevel.info;
    int counter1 = 10;
    int counter2 = 20;
    int f0() {
        hlSleep(1.seconds);
        return 1;
    }
    void f1() {
        while(--counter1 > 0) {
            hlSleep(100.msecs);
        }
    }
    void f2() {
        while(--counter2 > 0) {
            hlSleep(50.msecs);
        }
    }
    void f3() {
        auto t1 = task(&f1);
        auto t2 = task(&f2);
        t1.start();
        t2.start();
        auto v = callInThread(&f0);
        assert(counter1 == 0);
        assert(counter2 == 0);
        t1.wait();
        t2.wait();
        getDefaultLoop().stop();
    }
    auto t3 = task(&f3);
    t3.start();
    getDefaultLoop().run(3.seconds);
    info("test0 ok");
}

unittest {
    globalLogLevel = LogLevel.info;
    int f() {
        return 1;
    }
    auto v = callInThread(&f);
    assert(v == 1, "expected v==1, but received v=%d".format(v));
    info("test1 ok");
}

unittest {
    globalLogLevel = LogLevel.info;
    int f() {
        hlSleep(200.msecs);
        return 2;
    }
    auto v = callInThread(&f);
    assert(v == 2, "expected v==2, but received v=%d".format(v));
    info("test2 ok");
}

version(unittest) {
    class TestException : Exception {
        this(string msg, string file = __FILE__, size_t line = __LINE__) {
            super(msg, file, line);
        }
    }
}

unittest {
    globalLogLevel = LogLevel.info;
    int f() {
        hlSleep(200.msecs);
        throw new TestException("test exception");
    }
    assertThrown!TestException(callInThread(&f));
    info("test3a ok");
}

unittest {
    globalLogLevel = LogLevel.info;
    int f() {
        auto t = task((){
            hlSleep(200.msecs);
            throw new TestException("test exception");
        });
        t.start();
        t.wait();
        return 0;
    }
    assertThrown!TestException(callInThread(&f));
    info("test3b ok");
}

unittest {
    globalLogLevel = LogLevel.info;
    int f0() {
        hlSleep(100.msecs);
        return 4;
    }
    int f() {
        auto t = task(&f0);
        t.call();
        t.wait(200.msecs);
        return t.result;
    }
    auto r = callInThread(&f);
    assert(r == 4, "spawnTask returned %d, expected 4".format(r));
    info("test4 ok");
}

unittest {
    globalLogLevel = LogLevel.info;
    class TestException : Exception {
        this(string msg) {
            super(msg);
        }
    }
    int f() {
        hlSleep(100.msecs);
        throw new TestException("test exception");
    }
    assertThrown!TestException(callInThread(&f));
    info("test5 ok");
}

unittest {
    globalLogLevel = LogLevel.info;
    void f() {
        hlSleep(200.msecs);
    }
    callInThread(&f);
    info("test6 ok");
}


unittest {
    globalLogLevel = LogLevel.info;
    //auto oScheduler = scheduler;
    //scheduler = new MyScheduler();
    int f0() {
        //hlSleep(100.msecs);
        tracef("sleep done");
        return 6;
    }
    int f() {
        auto v = callInThread(&f0);
        tracef("got value %s", v);
        return v+1;
    }
    auto r = callInThread(&f);
    assert(r == 7, "spawnTask returned %d, expected 6".format(r));
    info("test7 ok");
    //scheduler = oScheduler;
}


unittest {
    info("=== test wait task ===");
    //auto oScheduler = scheduler;
    //scheduler = new MyScheduler();

    globalLogLevel = LogLevel.info;

    int f1(Duration d) {
        hlSleep(d);
        return 40;
    }

    int f2(Duration d) {
        auto t = task(&f1, d);
        t.call();
        t.wait();
        return t.result;
    }

    auto t = task(&f2, 500.msecs);

    auto tid = spawnTask(t, 1.seconds);

    receive(
        (const int i)
        {
            assert(i == 40, "expected 40, got %s".format(i));
        },
        (Variant v)
        {
            errorf("test wait task got variant %s of type %s", v, v.type);
            assert(0);
        }
    );

    //
    //scheduler = oScheduler;
}

unittest {
    info("=== test wait task with timeout ===");
    //
    // we call f2 which start f1(sleeping for 500 msecs) and wait it for 100 msecs
    // so 
    globalLogLevel = LogLevel.info;

    int f1(Duration d) {
        hlSleep(d);
        return 41;
    }

    bool f2(Duration d) {
        auto t = task(&f1, d);
        t.call();
        bool ready = t.wait(100.msecs);
        assert(!t.ready);
        return ready;
    }

    auto t = task(&f2, 500.msecs);
    spawnTask(t, 1.seconds);
    receive(
        (Exception e) {tracef("got exception"); assert(0);},
        (const bool b) {assert(!b, "got value %s instedad of false".format(b));},
        (Variant v) {tracef("got variant %s", v); assert(0);}
    );
}