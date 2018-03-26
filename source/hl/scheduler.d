module hl.scheduler;

import std.experimental.logger;

import core.thread;
import std.concurrency;
import std.datetime;
import std.format;
import std.traits;
import std.exception;
import core.sync.condition;

import hl.events;
import hl.loop;
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
    auto tid = Fiber.getThis();
    scope callback = delegate void (AppEvent e) @trusted {
        tid.call();
    };
    auto t = new Timer(d, callback);
    getDefaultLoop().startTimer(t);
    yield();
    info("returning from timer");
}

class Task(F, A...) : Fiber if (isCallable!F) {
    private {
        enum    Void = is(ReturnType!F==void);
        alias   R = ReturnType!F;
        F       _f;
        A       _args;
        bool    _ready;
        static if ( !Void ) {
            R       _result;
        }
    }

    @property
    pragma(inline)
    final bool ready() const {
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
        try {
            static if ( Void )
            {
                _f(_args);
            }
            else 
            {
                _result = _f(_args);
            } 
        } catch (Exception e) {
            error("Uncought exception in task function");
        }
        _ready = true;
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

class MyScheduler : Scheduler {
    /**
     * This simply runs op directly, since no real scheduling is needed by
     * this approach.
     */
    void start(void delegate() op)
    {
        op();
    }

    /**
     * Creates a new kernel thread and assigns it to run the supplied op.
     */
    void spawn(void delegate() op)
    {
        try{writefln("spawn %s", thisInfo.owner);}catch(Exception e){}
        auto t = new Thread(op);
        t.start();
    }

    /**
     * This scheduler does no explicit multiplexing, so this is a no-op.
     */
    void yield() nothrow
    {
        auto f = Fiber.getThis();
        if ( f is null ) {
            return;
        }
        f.yield();
    }

    /**
     * Returns ThreadInfo.thisInfo, since it is a thread-local instance of
     * ThreadInfo, which is the correct behavior for this scheduler.
     */
    @property ref ThreadInfo thisInfo() nothrow
    {
        return ThreadInfo.thisInfo;
    }

    /**
     * Creates a new Condition variable.  No custom behavior is needed here.
     */
    Condition newCondition(Mutex m) nothrow
    {
        return new Condition(m);
    }
    private {
    }
}

class NotMyScheduler : Scheduler {
    import core.sync.condition;

    class MyCondition : Condition
    {
        this(Mutex m) nothrow
        {
            super(m);
            notified = false;
            notification = new Notification();
            notification.subscribe((Notification n) @trusted {
                try{writefln("notified %s", thisTid);}catch(Exception e){}
            });
            try{writefln("new Condition");}catch(Exception e){}
        }

        override void wait() nothrow
        {
            try{writefln("wait Condition in %s", thisTid);}catch(Exception e){}
            //try tracef("waiting"); catch(Exception e) {}
            scope (exit) notified = false;

            while (!notified)
                switchContext();
        }

        override bool wait(Duration period) nothrow
        {
            import core.time : MonoTime;

            try{writefln("wait Condition in %s", thisTid);}catch(Exception e){}
            //try tracef("waiting with timeout"); catch(Exception e) {}
            scope (exit) notified = false;

            for (auto limit = MonoTime.currTime + period;
                 !notified && !period.isNegative;
                 period = limit - MonoTime.currTime)
            {
                yield();
            }
            return notified;
        }

        override void notify() nothrow
        {
            try{writefln("notify Condition from %s", thisTid);}catch(Exception e){}
            //try tracef("notify"); catch(Exception e) {}
            try {
                notified = true;
                getDefaultLoop().postNotification(notification);
                switchContext();
            } catch (Exception e) {
                try{errorf("got exception on notify %s", e);}catch(Exception ee){}
            }
        }

        override void notifyAll() nothrow
        {
            //try tracef("notifyAll"); catch(Exception e) {}
            notified = true;
            switchContext();
        }

    private:
        void switchContext() nothrow
        {
            try{writefln("switchContext Condition from %s", thisTid);}catch(Exception e){}
             mutex_nothrow.unlock_nothrow();
            scope (exit) mutex_nothrow.lock_nothrow();
            yield();
        }

        private bool notified;
        private Notification notification;
    }

    private {
        class MyFiber : Fiber {
            ThreadInfo info;
            this(void delegate() op) nothrow
            {
                super(op);
            }
        }
    }

    @property ref ThreadInfo thisInfo() nothrow {
        auto f = cast(MyFiber) Fiber.getThis();

        if (f !is null)
            return f.info;
        return ThreadInfo.thisInfo;
    }

    void start(void delegate() op) {
        op();
    }
    void spawn(void delegate() op) {
        //try { tracef("spawninig"); } catch (Exception e) { }
        create(op);
        //yield();
    }
    override void yield() {
        debug try { trace("yielding"); } catch(Exception e) { }
        Fiber.yield();
    }
    override Condition newCondition(Mutex m) {
        //try { tracef("newCondition"); } catch(Exception e) { }
        return new MyCondition(m);
    }

    private:

    void create(void delegate() op) {
        MyFiber t;
        void wrap() {
            scope (exit) {
                thisInfo.cleanup();
            }
            op();
        }
        t = new MyFiber(&wrap);
        t.call();
    }
}

unittest {
    info("=== test scheduler ===");
    import std.stdio;
    import std.format;

    auto oScheduler = scheduler;
    scheduler = new MyScheduler();

    globalLogLevel = LogLevel.trace;
    int i;
    //shared void delegate() test1 = () {
    //    auto started = Clock.currTime;
    //    hlSleep(500.msecs);
    //    i = 1;
    //    assert(Clock.currTime - started >= 450.msecs, "failed to sleep 500ms: %s".format(Clock.currTime - started));
    //};
    //
    //spawn(test1);

    shared void delegate() test0 = () {
        infof("from test0 %s", Fiber.getThis);
        i++;
    };

    shared void delegate(Duration) test2 = (Duration d) {
        auto started = Clock.currTime;
        info("test2 started");
        spawn(test0);
        hlSleep(d);
        i += 1;
        assert(Clock.currTime - started >= 450.msecs, "failed to sleep 500ms: %s".format(Clock.currTime - started));
    };


    shared void delegate(Tid) run = (Tid parent) {
        stdThreadLocalLog = new StdForwardLogger(globalLogLevel);
        auto t = task(test2, 1500.msecs);
        auto throwable = t.call();
        getDefaultLoop.run(5.seconds);
        parent.send(0);
        assert(t.ready);
        assert(t.state == Fiber.State.TERM);
        getDefaultLoop.deinit();
        t.reset();
    };
    //spawn(test2, 1.seconds);

    auto tid = spawn(run, thisTid);
    while(true) {
        import std.variant;
        try {
            receive(
                (Variant v) {writefln("got: %s", v);}
            );
        } catch (LinkTerminated e) {
            writeln("Link terminated");
        }
        break;
    }
    //scheduler.start({
    //    getDefaultLoop().run(1.seconds);
    //});
    assert(i==2, "spawn failed, i=%d".format(i));
    scheduler = oScheduler;
}
