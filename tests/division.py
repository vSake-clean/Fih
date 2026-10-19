#!/usr/bin/env python3
"""Dzielenie i reszta na granicach 32/53/64 bitów, ze znakami (obcinanie
w stronę zera, reszta ma znak dzielnej, jak w C)."""
import random, subprocess, sys, tempfile, os
r = random.Random(5); L = []; E = []
def trunc(a, b):
    q = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1); return q, a - q * b
edges = [0, 1, 2, 3, 7, 10, 99, 100, 65535, 65536, 2**31 - 2, 2**31 - 1, 2**31, 2**31 + 1, 2**32, 2**53, 2**62]
vals = {s * (e + d) for e in edges for d in (-1, 0, 1) for s in (1, -1)}
vals = [v for v in vals if abs(v) < 2**62]
pairs = [(a, b) for a in vals for b in vals if b]
pairs += [(r.randint(-2**31, 2**31 - 1), r.choice([1, -1]) * r.randint(1, 2**31)) for _ in range(20000)]
lit = lambda x: f"({x})" if x >= 0 else f"(0-{-x})"
for a, b in pairs:
    q, m = trunc(a, b)
    L.append(f'calc("{lit(a)} / {lit(b)}")'); E.append(str(q))
    L.append(f'calc("{lit(a)} % {lit(b)}")'); E.append(str(m))
p = os.path.join(tempfile.mkdtemp(), "d.fh"); open(p, "w").write("\n".join(L) + "\n")
got = subprocess.run([sys.argv[1], p], capture_output=True, text=True).stdout.split("\n")[:-1]
sys.exit(0 if got == E else 1)
