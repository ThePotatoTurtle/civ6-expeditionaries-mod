#!/usr/bin/env python3
"""run_records_test.py - runs tests/offline/test_records.lua under Lua 5.1 (lupa.lua51).

WP1.2 offline tests for EFV_Records (store, commit, serializer, dump) and EFV_Notify.
Self-contained: the test file carries its own minimal fake engine.

Usage:  python tests/offline/run_records_test.py
Exit code: 0 = all passed, 1 = failures or no RESULT line, 2 = lupa missing.
"""
from __future__ import annotations

import os
import re
import sys


def main() -> int:
    try:
        from lupa import lua51  # type: ignore
    except ImportError:
        print("lupa with Lua 5.1 is required: pip install lupa")
        return 2
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", ".."))
    test = os.path.join(here, "test_records.lua")

    lines: list[str] = []
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.globals().EFV_ROOT = root.replace("\\", "/")
    rt.globals().print = lambda *a: lines.append("\t".join("nil" if x is None else str(x) for x in a))
    with open(test, "r", encoding="utf-8") as f:
        src = f.read()
    try:
        chunk = rt.eval("function(src, name) return assert(loadstring(src, name)) end")(src, "@" + test)
        chunk()
    except Exception as exc:  # Lua error outside a test
        lines.append("ERROR %s" % exc)

    for line in lines:
        print(line)
    result = None
    for line in lines:
        m = re.match(r"RESULT passed=(\d+) failed=(\d+)", line)
        if m:
            result = (int(m.group(1)), int(m.group(2)))
    if result is None:
        print("run_records_test: no RESULT line (the test script aborted)")
        return 1
    return 0 if result[1] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
