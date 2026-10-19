#!/usr/bin/env python3
"""Test parsowania liczb (ścieżka SWAR i skalarna): każda długość 1..25 cyfr,
zera wiodące, różne znaki po liczbie."""
import random, subprocess, sys, tempfile, os
r = random.Random(7); lines = []; exp = []
MAX = (1 << 63) - 1
for length in range(1, 26):
    for _ in range(40):
        digits = "".join(r.choice("0123456789") for _ in range(length))
        if r.random() < 0.2: digits = "0" * r.randint(1, 5) + digits
        v = int(digits)
        if v > MAX: continue
        for tail in ["", " ", "+0", "*1", ")", "  +  0", "-0      ", "%1000000007"]:
            expr = f"({digits})" if tail == ")" else digits + tail
            lines.append(f'calc("{expr}")')
            exp.append(str(v % 1000000007 if tail == "%1000000007" else v))
path = os.path.join(tempfile.mkdtemp(), "num.fh")
open(path, "w").write("\n".join(lines) + "\n")
got = subprocess.run([sys.argv[1], path], capture_output=True, text=True).stdout.split("\n")[:-1]
bad = sum(e != g for e, g in zip(exp, got)) + abs(len(got) - len(exp))
sys.exit(1 if bad else 0)
