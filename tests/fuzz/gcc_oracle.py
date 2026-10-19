#!/usr/bin/env python3
"""Druga, niezależna wyrocznia: gcc. Losowe wyrażenia calc są kompilowane jako
C (int64, -fwrapv) i wyniki porównywane z Fih w obu trybach. Wyrażenia z dzieleniem
przez zero albo przepełnieniem (w C zachowanie niezdefiniowane, w Fih błąd)
są pomijane.

użycie: gcc_oracle.py [liczba_wyrażeń] [ziarno]"""
import os, random, subprocess, sys, tempfile
FIH = os.environ.get("FIH") or os.path.join(os.path.dirname(__file__), "..", "..", "fih")
n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 30)
r = random.Random(seed)
I64 = 1 << 63

def num():
    k = r.random()
    if k < 0.5: return str(r.randint(0, 9999))
    if k < 0.8: return str(r.randint(0, 2**31))
    if k < 0.95: return str(r.randint(0, I64 - 1))
    return r.choice(["0", "1", str(I64 - 1), "4294967296", "2147483648"])

def expr(d=0):
    k = r.random()
    if d > 5 or k < 0.3: return num()
    if k < 0.4: return "(" + expr(d + 1) + ")"
    if k < 0.5: return "-" + expr(d + 1)
    return expr(d + 1) + r.choice([" + ", " - ", " * ", " / ", " % ", "+", "*"]) + expr(d + 1)

def c_safe(e):
    """Liczy wyrażenie tak jak C z -fwrapv; None gdy UB (dzielenie przez 0, MIN/-1)."""
    def wrap(v):  # przepełnienie: w C zachowanie niezdefiniowane, w Fih błąd — pomijamy
        if not -I64 <= v < I64: raise ZeroDivisionError
        return v
    toks = e.replace("(", " ( ").replace(")", " ) ").replace("+", " + ").replace("-", " - ").replace("*", " * ").replace("/", " / ").replace("%", " % ").split()
    pos = 0
    def peek(): return toks[pos] if pos < len(toks) else None
    def take():
        nonlocal pos; pos += 1; return toks[pos - 1]
    def factor():
        t = take()
        if t == "-": return wrap(-factor())
        if t == "(":
            v = add(); take(); return v
        return int(t)
    def mul():
        v = factor()
        while peek() in ("*", "/", "%"):
            op = take(); b = factor()
            if op == "*": v = wrap(v * b); continue
            if b == 0 or (v == -I64 and b == -1): raise ZeroDivisionError
            q = abs(v) // abs(b) * (1 if (v < 0) == (b < 0) else -1)
            v = q if op == "/" else v - q * b
        return v
    def add():
        v = mul()
        while peek() in ("+", "-"):
            op = take(); b = mul(); v = wrap(v + b if op == "+" else v - b)
        return v
    try: return add()
    except ZeroDivisionError: return None

exprs = []
while len(exprs) < n:
    e = expr()
    if c_safe(e) is not None: exprs.append(e)
tmp = tempfile.mkdtemp()
fh, c, exe, bin_ = (os.path.join(tmp, x) for x in ("p.fh", "p.c", "p_c", "p_fih"))
open(fh, "w").write("".join(f'calc("{e}")\n' for e in exprs))
CH = 500
with open(c, "w") as f:
    f.write("#include <stdio.h>\n#include <stdint.h>\n")
    for k in range(0, n, CH):
        f.write(f"static void part{k}(void) {{\n")
        for e in exprs[k:k + CH]:
            ce = " ".join(t if not t.isdigit() else f"((int64_t){t}ULL)" for t in e.replace("(", " ( ").replace(")", " ) ").replace("+", " + ").replace("-", " - ").replace("*", " * ").replace("/", " / ").replace("%", " % ").split())
            f.write(f'    printf("%lld\\n", (long long)({ce}));\n')
        f.write("}\n")
    f.write("int main(void){\n" + "".join(f"part{k}();\n" for k in range(0, n, CH)) + "return 0;}\n")
subprocess.run(["gcc", "-O1", "-fwrapv", "-w", "-o", exe, c], check=True)
want = subprocess.run([exe], capture_output=True).stdout
got = subprocess.run([FIH, fh], capture_output=True).stdout
subprocess.run([FIH, "build", fh, "-o", bin_], check=True)
got2 = subprocess.run([bin_], capture_output=True).stdout
w, g, g2 = want.split(b"\n"), got.split(b"\n"), got2.split(b"\n")
bad = [i for i in range(n) if not (w[i] == g[i] == g2[i])]
for i in bad[:5]:
    print(f"RÓŻNICA: calc(\"{exprs[i]}\"): gcc {w[i]!r}, fih {g[i]!r}, build {g2[i]!r}")
print(f"ziarno {seed}: {n} wyrażeń porównanych z gcc, niezgodności: {len(bad)}")
sys.exit(1 if bad else 0)
