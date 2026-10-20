#!/usr/bin/env python3
"""Generuje src/flt_tab.inc: tablicę g(k) dla wypisywania ułamków (Schubfach,
R. Giulietti, "The Schubfach way to render doubles"). Dla k = -324..292:
10^-k = beta * 2^r, 2^125 <= beta < 2^126, g = floor(beta) + 1, zapisane jako
dq g1, g0 (wyższe i niższe 63 bity). użycie: python3 tools/flt_tab.py"""
import math, os
from fractions import Fraction

K_MIN, K_MAX = -324, 292
M63 = (1 << 63) - 1
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "flt_tab.inc")
with open(path, "w") as f:
    f.write("; flt_tab.inc — wygenerowane przez tools/flt_tab.py, nie edytować\n")
    f.write("rt_flt_g:\n")
    for k in range(K_MIN, K_MAX + 1):
        r = ((-k * 913124641741) >> 38) - 125
        beta = Fraction(10) ** (-k) / Fraction(2) ** r
        assert 2 ** 125 <= beta < 2 ** 126
        g = math.floor(beta) + 1
        f.write(f"    dq 0x{g >> 63:016x}, 0x{g & M63:016x}  ; {k}\n")
