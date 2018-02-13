module hl.common;

import std.conv;
import core.stdc.string: strerror;

auto s_strerror(T)(T e) @trusted {
    return to!string(strerror(e));
}

@safe unittest {
}
