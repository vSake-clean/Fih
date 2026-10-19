#!/usr/bin/env python3
"""Dzielenie i reszta przez stałą (kompilator zamienia je na mnożenie przez
"magiczną" liczbę): x / C i x % C dla wielu C i x, porównane z wyrocznią.
użycie: division_const.py ścieżka_do_fih"""
import os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "fuzz"))
import oracle

I64 = (1 << 63) - 1
r = random.Random(7)
ds = [1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 25, 100, 125, 641, 1000, 4294967296, 4294967297,
      1 << 62, (1 << 62) + 1, I64, I64 - 1, 3 ** 39, 6700417]
ds += [r.randint(2, 10 ** 6) for _ in range(40)] + [r.randint(2, I64) for _ in range(40)]
ns = [0, 1, -1, 2, -2, 7, -7, I64, -I64, 1000000007, -1000000007]
ns += [r.randint(-I64, I64) for _ in range(25)]
lines = []
for n in ns:
    lines.append(f"x = {n}" if n >= 0 else f"x = -{-n}")
    lines.append("y = x - 1")       # y = n - 1 (też INT64_MIN dla n = -I64)
    for d in ds:
        for c in (f"{d}", f"-{d}"):
            lines += [f"calc(x / {c})", f"calc(x % {c})", f"calc(y / {c})", f"calc(y % {c})"]
src = ("\n".join(lines) + "\n").encode()
exp = oracle.run(src)[:3]
tmp = tempfile.mkdtemp()
p = os.path.join(tmp, "d.fh")
open(p, "wb").write(src)
got = subprocess.run([sys.argv[1], p], capture_output=True)
if (got.stdout, got.stderr, got.returncode) != exp:
    a, b = got.stdout.split(b"\n"), exp[0].split(b"\n")
    bad = next(i for i in range(min(len(a), len(b))) if a[i] != b[i])
    print(f"różnica w wyniku nr {bad}: fih {a[bad]!r}, oczekiwano {b[bad]!r}")
    sys.exit(1)
print(f"dzielenie przez stałe: {len(lines)} linii zgodnych")
