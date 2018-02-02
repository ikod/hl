module hl.common;

import core.stdc.string: strerror;

auto s_strerror(T)(T e) @trusted {
    return strerror(e);
}

@safe unittest {
}
