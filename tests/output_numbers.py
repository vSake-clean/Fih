#!/usr/bin/env python3
"""Wypisywanie liczb: każda potęga 10 i jej sąsiedzi, potęgi 2, wartości
ujemne, INT64_MIN/INT64_MAX — w obu trybach (interpretacja i build)."""
import subprocess, sys, tempfile, os
fih = sys.argv[1]
vals = set()
for k in range(19):
    for d in (-1, 0, 1):
        vals.add(10**k + d)
for k in range(63):
    for d in (-1, 0, 1):
        vals.add(2**k + d)
vals |= {0, 9223372036854775807}
lines, exp = [], []
for v in sorted(vals):
    if 0 <= v <= 9223372036854775807:
        lines.append(f'calc("{v}")'); exp.append(str(v))
        lines.append(f'calc("-{v}")'); exp.append(str(-v))
lines.append('calc("-9223372036854775807 - 1")'); exp.append(str(-2**63))
tmp = tempfile.mkdtemp(); path = os.path.join(tmp, "n.fh")
open(path, "w").write("\n".join(lines) + "\n")
want = "\n".join(exp) + "\n"
got = subprocess.run([fih, path], capture_output=True, text=True).stdout
subprocess.run([fih, "build", path, "-o", path[:-3]], check=True)
got2 = subprocess.run([path[:-3]], capture_output=True, text=True).stdout
sys.exit(0 if got == want and got2 == want else 1)
