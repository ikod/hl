#!/usr/bin/env dub
/+ dub.sdl:
    name "t0"
    dflags "-I../source"
    dflags "-release"
    lflags "-L.."
    lflags "-lhl"
+/
// cd to tests and run with "dub run --single t0.d"
void main() {
    import std.datetime;
    import std.stdio;
    import std.experimental.logger;
    import hl;

    globalLogLevel(LogLevel.info);
    auto loop = getEventLoop();
    HandlerDelegate handler = (AppEvent e) {
        //writeln("Hello from Handler");
        //loop.stop();
    };
    auto timer = new Timer(1.seconds, handler);
    loop.startTimer(timer);
    writeln("Starting loop1, wait 1.2 seconds ...");
    loop.run(1200.msecs);
    writeln("loop1 stopped");

    for(int i; i < 10; i++) {
        timer = new Timer(1.seconds, handler);
        loop.startTimer(timer);
        loop.stopTimer(timer);
    }
    writeln("10_000 timers start-stopped");
    Timer[] ts = new Timer[](100_000);
    for(int i; i<100_000; i++) {
        ts[i] = new Timer(1.seconds, handler);
        loop.startTimer(ts[i]);
    }
    writeln("100_000 timers started");
    for(int i; i<100_000; i++) {
        loop.stopTimer(ts[i]);
    }
    writeln("100_000 timers stopped");
    timer = new Timer(1.seconds, handler);
    loop.startTimer(timer);
    writeln("Starting loop2, wait 1seconds ...");
    loop.run(1.seconds);
    writeln("loop2 stopped");
}
