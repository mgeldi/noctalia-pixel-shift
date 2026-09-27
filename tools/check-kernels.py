#!/usr/bin/env python3
"""engine.luau carries a verbatim copy of core/kernels.luau's KERNELS block
(Noctalia runs required modules without fast builtin calls, the entry script
gets them). Fail when the two copies differ."""
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent


def block(path):
    text = (root / path).read_text()
    begin, end = "-- BEGIN KERNELS\n", "-- END KERNELS\n"
    if begin not in text or end not in text:
        sys.exit(f"{path}: KERNELS markers missing")
    return text.split(begin, 1)[1].split(end, 1)[0]


if block("pixel-shift/core/kernels.luau") != block("pixel-shift/engine.luau"):
    sys.exit("engine.luau KERNELS block differs from core/kernels.luau; copy it again")
print("kernels in sync")
