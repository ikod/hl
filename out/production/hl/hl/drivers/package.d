module hl.drivers;

version(OSX) {
    public import hl.drivers.osx;
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
