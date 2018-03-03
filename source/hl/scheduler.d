module hl.scheduler;

import std.experimental.logger;

import core.thread;
import std.concurrency;
import std.datetime;

import hl.events;
import hl.loop;

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
}

class MyScheduler : Scheduler {
    import core.sync.condition;

    class MyCondition : Condition
    {
        this(Mutex m) nothrow
        {
            super(m);
            notified = false;
        }

        override void wait() nothrow
        {
            //try tracef("waiting"); catch(Exception e) {}
            scope (exit) notified = false;

            while (!notified)
                switchContext();
        }

        override bool wait(Duration period) nothrow
        {
            import core.time : MonoTime;

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
            //try tracef("notify"); catch(Exception e) {}
            notified = true;
            switchContext();
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
            mutex_nothrow.unlock_nothrow();
            scope (exit) mutex_nothrow.lock_nothrow();
            yield();
        }

        private bool notified;
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
    override void yield() @nogc {
        //try { tracef("yielding"); } catch(Exception e) { }
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

    globalLogLevel = LogLevel.info;
    int i;
    shared void delegate() test1 = () {
        auto started = Clock.currTime;
        hlSleep(500.msecs);
        i = 1;
        assert(Clock.currTime - started >= 499.msecs, "failed to sleep 500ms: %s".format(Clock.currTime - started));
    };

    spawn(test1);

    scheduler.start({
        getDefaultLoop().run(1.seconds);
    });
    assert(i==1, "spawn failed");
    scheduler = oScheduler;
}
