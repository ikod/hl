module t2;

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
    globalLogLevel = LogLevel.trace;

    int   tm = 1000;      // recv/send timeout in ms
    int   td  = 1;   // test duration in seconds
    bool  fallback = false;
    getopt(args, "tm", &tm, "dur", &td, "fallback", &fallback);


    auto loop = getDefaultLoop(!fallback ? Mode.NATIVE : Mode.FALLBACK );
    auto client = new hlSocket();
    auto fd = client.open();
    assert(fd >= 0);
    scope(exit) {
        client.close();
    }

    int counter = 0;
    immutable limit = 2;
    
    
    immutable(ubyte)[] input;
    immutable(ubyte)[] response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".representation;
    string request = "GET / HTTP/1.1\r\nId: %d\r\n\r\n";

    void server_handler(hlSocket s) @safe {
        tracef("server accepted on %s", s.fileno());
        IORequest iorq;
        iorq.to_read = 512;
        iorq.callback = (IOResult r) {
            if ( r.timedout ) {
                s.close();
                return;
            }
            writeln(cast(string)r.input);
            s.send(response);
            s.close();
        };
        s.io(loop, iorq, dur!"seconds"(10));
    }

    void client_handler(AppEvent e) @safe {
        tracef("connection app handler");
        if ( e & AppEvent.ERR ) {
            infof("error on %s", client);
            client.close();
            return;
        }
        tracef("sending to %s", client);
        auto rc = client.send(request.format(counter).representation());
        tracef("send returned %d", rc);
        IORequest iorq;
        iorq.to_read = 512;
        iorq.callback = (IOResult r) {
            if ( r.timedout ) {
                info("Client timeout waiting for response");
                client.close();
                return;
            }
            writeln(cast(string)r.input);
            client.close();
            if ( ++counter < limit ) {
                client = new hlSocket();
                client.open();
                client.connect("127.0.0.1:16000", loop, &client_handler, dur!"seconds"(5));
            }
        };
        client.io(loop, iorq, 10.seconds);
    }

    auto server = new hlSocket();
    server.open();
    assert(server.fileno() >= 0);
    scope(exit) {
        debug tracef("closing server socket %s", server);
        server.close();
    }
    tracef("server listen on %d", server.fileno());
    server.bind("0.0.0.0:16000");
    server.listen();
    server.accept(loop, &server_handler);

    loop.startTimer(new Timer(50.msecs,  (AppEvent e) @safe {
        client.connect("127.0.0.1:16000", loop, &client_handler, dur!"seconds"(5));
    }));

    loop.run(dur!"seconds"(td));
}