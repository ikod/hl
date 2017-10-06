module hl.drivers;

version(OSX) {
    public import hl.drivers.kqueue;
} else
version(linux) {
    public import hl.drivers.epoll;
} else {
    struct NativeEventLoopImpl {
        bool invalid;
        void initialize();
    }
}


public import hl.drivers.select;
