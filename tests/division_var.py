#!/usr/bin/env python3
"""Dzielenie i reszta przez zmienną (kompilator używa idiv 32-bitowego, gdy
obie liczby mieszczą się w 32 bitach): wartości na granicach 32/64 bitów,
porównane z wyrocznią. użycie: division_var.py ścieżka_do_fih"""
import os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "fuzz"))
import oracle

I64, I32 = (1 << 63) - 1, (1 << 31) - 1
edge = [0, 1, -1, 2, -2, 7, -7, I32, -I32, -I32 - 1, I32 + 1, -I32 - 2, 1 << 32, -(1 << 32),
        I64, -I64, -I64 - 1, 1000000007, -1000000007]
r = random.Random(3)
vals = edge + [r.randint(-I32 - 1, I32) for _ in range(15)] + [r.randint(-I64 - 1, I64) for _ in range(10)]
lit = lambda v: str(v) if v >= 0 else (f"-{-v}" if v != -I64 - 1 else "-9223372036854775807 - 1")
lines = []
for a in vals:
    for b in vals:
        if b == 0 or (a == -I64 - 1 and b == -1):
            continue                    # błędy w trakcie sprawdzają inne testy
        lines += [f"a = {lit(a)}", f"b = {lit(b)}", "calc(a / b)", "calc(a % b)"]
src = ("\n".join(lines) + "\n").encode()
exp = oracle.run(src)[:3]
p = os.path.join(tempfile.mkdtemp(), "d.fh")
open(p, "wb").write(src)
for args in ([sys.argv[1], p],):
    got = subprocess.run(args, capture_output=True)
    if (got.stdout, got.stderr, got.returncode) != exp:
        a, b = got.stdout.split(b"\n"), exp[0].split(b"\n")
        bad = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), None)
        print(f"różnica w wyniku nr {bad}: fih {a[bad]!r}, oczekiwano {b[bad]!r}" if bad is not None else got.stderr)
        sys.exit(1)
print(f"dzielenie przez zmienną: {len(lines) // 2} działań zgodnych")
