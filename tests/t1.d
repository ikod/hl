module t1;

import std.stdio;
import std.datetime;
import std.experimental.logger;
import std.typecons;
import core.thread;
import std.string;
import std.getopt;

import hl;
import hl.socket;
import hl.events;
import nbuff;



void main(string[] args){
    globalLogLevel = LogLevel.info;

    auto loop = getEventLoop();
    auto server = new Socket();
    auto fd = server.open();
    assert(fd >= 0);
    scope(exit) {
        server.close();
    }

    int opt = 1000;      // recv/send timeout in ms
    int td  = 10;   // test duration in seconds
    getopt(args, "tmo", &opt, "dur", &td);
    
    immutable(ubyte)[] input;
    immutable(ubyte)[] output = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".representation;

    void exchange(Socket s) @safe {
        auto done = (IOResult r) {
            if ( r.timedout ) {
                info("Timedout on write");
            }
            s.close();
        };
        auto on_read = (IOResult r) {
            if ( r.timedout ) {
                infof("Timedout on read %d", s.fileno());
                s.close();
                return;
            }
            tracef("got input, ready to send");
            IORequest out_iorq;
            out_iorq.output = output;
            out_iorq.callback = done;
            s.io(loop, out_iorq, dur!"msecs"(opt));
        };
        IORequest in_iorq;
        in_iorq.to_read = 512;
        in_iorq.callback = on_read;
        s.io(loop, in_iorq, dur!"msecs"(opt));
    }
    void delegate(Socket) accept = (Socket s) {
        exchange(s);
    };
    server.bind("127.0.0.1:16000");
    server.listen(500);
    server.accept(loop, accept);
    loop.run(dur!"seconds"(td));
}
