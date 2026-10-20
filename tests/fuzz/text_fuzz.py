#!/usr/bin/env python3
"""Losowe programy na tekstach (0.4) porównywane z Pythonem.

Sprawdza łączenie (także z liczbami), +=, len, t[i], t[a:b] (UTF-8: znaki,
nie bajty), == i !=, print/write tekstu i liczby, błąd "indeks poza tekstem".
Każdy program jest uruchamiany przez JIT (fih p.fh) i po fih build.

użycie: text_fuzz.py [liczba programów] [ziarno]
"""
import os
import random
import subprocess
import sys
import tempfile

FIH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fih")
PIECES = ["a", "b", "ż", "ó", "ł", "🐟", " ", "ab", "xyz", "", "\\n", "\\\"", "#"]
TEXTS = ["t0", "t1", "t2"]
NUMS = ["n0", "n1"]


class IndexErr(Exception):
    pass


def lit(r):
    src = "".join(r.choice(PIECES) for _ in range(r.randint(0, 3)))
    val = src.replace("\\n", "\n").replace('\\"', '"')
    return '"' + src + '"', val


def num_expr(r, env, depth):
    c = r.randint(0, 4 if depth < 3 else 1)
    if c == 0:
        v = r.randint(-3, 9)
        return (str(v) if v >= 0 else "(0 - %d)" % -v), v
    if c == 1:
        n = r.choice(NUMS)
        return n, env[n]
    if c == 2:
        s, v = text_expr(r, env, depth + 1)
        return "len(" + s + ")", len(v)
    if c == 3:
        a, av = text_expr(r, env, depth + 1)
        b, bv = text_expr(r, env, depth + 1)
        op = r.choice(["==", "!="])
        return "(" + a + " " + op + " " + b + ")", int((av == bv) == (op == "=="))
    a, av = num_expr(r, env, depth + 1)
    b, bv = num_expr(r, env, depth + 1)
    return "(" + a + " + " + b + ")", av + bv


def text_expr(r, env, depth):
    c = r.randint(0, 5 if depth < 3 else 1)
    if c == 0:
        return lit(r)
    if c == 1:
        t = r.choice(TEXTS)
        return t, env[t]
    if c == 2:
        a, av = text_expr(r, env, depth + 1)
        b, bv = text_expr(r, env, depth + 1)
        return "(" + a + " + " + b + ")", av + bv
    if c == 3:
        a, av = text_expr(r, env, depth + 1)
        b, bv = num_expr(r, env, depth + 1)
        if r.random() < 0.5:
            return "(" + a + " + " + b + ")", av + str(bv)
        return "(" + b + " + " + a + ")", str(bv) + av
    if c == 4:
        a, av = text_expr(r, env, depth + 1)
        if av and r.random() < 0.9:     # zwykle poprawny indeks (też ujemny)
            iv = r.randrange(-len(av), len(av))
            i = str(iv) if iv >= 0 else "-" + str(-iv)
        else:
            i, iv = num_expr(r, env, depth + 1)
        if not -len(av) <= iv < len(av):
            raise IndexErr(a + "[" + i + "]")
        return a + "[" + i + "]", av[iv]
    a, av = text_expr(r, env, depth + 1)
    lo = hi = ""
    lov, hiv = None, None
    if r.random() < 0.7:
        lo, lov = num_expr(r, env, depth + 1)
    if r.random() < 0.7:
        hi, hiv = num_expr(r, env, depth + 1)
    return a + "[" + lo + ":" + hi + "]", av[lov:hiv]


def program(r):
    env = {"t0": "", "t1": "ż", "t2": "abc", "n0": 0, "n1": 5}
    lines = ['t0 = ""', 't1 = "ż"', 't2 = "abc"', "n0 = 0", "n1 = 5"]
    out = []
    err = None
    for _ in range(r.randint(1, 12)):
        line_no = len(lines) + 1
        kind = r.randint(0, 5)
        try:
            if kind == 0:
                t = r.choice(TEXTS)
                s, v = text_expr(r, env, 0)
                lines.append(t + " = " + s)
                env[t] = v
            elif kind == 1:
                t = r.choice(TEXTS)
                if r.random() < 0.5:
                    s, v = text_expr(r, env, 0)
                else:
                    s, nv = num_expr(r, env, 0)
                    v = str(nv)
                lines.append(t + " += " + s)
                env[t] += v
            elif kind == 2:
                s, v = text_expr(r, env, 0)
                lines.append("print(" + s + ")")
                out.append(v + "\n")
            elif kind == 3:
                s, v = num_expr(r, env, 0)
                lines.append("print(" + s + ")")
                out.append(str(v) + "\n")
            elif kind == 4:
                s, v = text_expr(r, env, 0)
                lines.append("write(" + s + ")")
                out.append(v)
            else:
                n = r.choice(NUMS)
                s, v = num_expr(r, env, 0)
                lines.append(n + " = " + s)
                env[n] = v
        except IndexErr:
            # statement with an out-of-range index: the program stops here
            lines.append('print("x" + t2[len(t2)])')
            err = "fih: błąd w linii %d: indeks poza tekstem\n" % line_no
            break
    return "\n".join(lines) + "\n", "".join(out), err


def run(cmd, d):
    p = subprocess.run(cmd, capture_output=True, cwd=d)
    return p.returncode, p.stdout.decode(), p.stderr.decode()


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 30)
    r = random.Random(seed)
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "p.fh")
        for i in range(n):
            src, out, err = program(r)
            with open(p, "w") as f:
                f.write(src)
            want = (1 if err else 0, out, err or "")
            got = run([FIH, p], d)
            ok = got == want
            if ok and i % 4 == 0:   # co czwarty także po fih build
                b = run([FIH, "build", p, "-o", os.path.join(d, "b")], d)
                ok = b[0] == 0 and run([os.path.join(d, "b")], d) == want
            if not ok:
                bad += 1
                if bad <= 3:
                    print("NIEZGODNOŚĆ\n" + src + "\noczekiwano", repr(want), "\notrzymano", repr(got))
    print(f"ziarno {seed}: {n} programów z tekstami, niezgodności: {bad}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
