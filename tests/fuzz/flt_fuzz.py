#!/usr/bin/env python3
"""Losowe programy z ułamkami (import math, 0.4) porównywane z Pythonem.

Sprawdza literały z kropką, + - * / // % na liczbach całkowitych, ułamkach
i ich mieszance, zmienne zmieniające rodzaj (liczby dynamiczne), porównania
(też łańcuchy i dokładne porównanie liczby całkowitej z ułamkiem), and / or /
not, minus, wypisywanie (zapis jak repr w Pythonie), łączenie z tekstem,
indeksy (ułamek w indeksie to błąd), if / while oraz błędy: przepełnienie,
dzielenie przez zero, "tu potrzebna jest liczba całkowita".

Różnice względem Pythona, zgodne z opisem języka: // obcina w stronę zera,
% ma znak dzielnej (jak fmod), dzielenie przez 0.0 to błąd, porównania
i and / or / not dają 1 albo 0.

użycie: flt_fuzz.py [liczba programów] [ziarno]
"""
import math
import os
import random
import subprocess
import sys
import tempfile

FIH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fih")
I_MAX = (1 << 63) - 1
I_MIN = -(1 << 63)
VARS = ["v0", "v1", "v2", "v3"]
INTS = [0, 1, 2, 3, 7, 10, 100, 1 << 31, (1 << 53) + 1, 1 << 62, I_MAX, 3037000499]
FLTS = ["0.5", "0.1", "0.2", "2.25", "3.0", "0.0", "1234.5678", "7.5", "0.000001",
        "9007199254740993.0", "1" + "0" * 20 + ".5", "1" + "0" * 300 + ".0", "123456789.987654321"]
CMP = ["<", "<=", ">", ">=", "==", "!="]
TX = "abcdef"
MSG = {
    "ovf": "przepełnienie: wynik poza zakresem liczb 64-bitowych",
    "div": "dzielenie przez zero",
    "idx": "indeks poza tekstem",
    "int": "tu potrzebna jest liczba całkowita",
    "dom": "argument spoza dziedziny funkcji matematycznej",
    "rng": "wynik za duży, by zapisać go jako ułamek",
}


def to_int(f, v):
    if isinstance(v, int):
        return v
    if v != v:
        raise FErr("dom")
    if math.isinf(v):
        raise FErr("ovf")
    return chk(f(v))


def m_sqrt(v):
    v = float(v)
    if v < 0:
        raise FErr("dom")
    return math.sqrt(v)


def m_pow(a, b):
    if isinstance(a, int) and isinstance(b, int):
        if b >= 0:
            if abs(a) >= 2 and b > 64:
                raise FErr("ovf")
            return chk(a ** b)
        if a == 0:
            raise FErr("div")
    try:
        return math.pow(float(a), float(b))
    except ValueError:
        raise FErr("dom")
    except OverflowError:
        raise FErr("rng")


def m_round2(a, n):
    if not isinstance(n, int):
        raise FErr("int")
    if n > 400:
        return a
    if n < -400:
        return 0 if isinstance(a, int) else (a if math.isinf(a) or a != a else math.copysign(0.0, a))
    try:
        return chk(round(a, n))
    except OverflowError:
        raise FErr("rng")


def m_minmax(op, vals):
    acc = vals[0]
    for v in vals[1:]:
        if (v < acc) if op == "min" else (v > acc):
            acc = v
    return acc


def m_abs(v):
    return chk(abs(v))


class FErr(Exception):
    pass


def chk(v):
    if isinstance(v, int) and not I_MIN <= v <= I_MAX:
        raise FErr("ovf")
    return v


def truth(v):
    return v != 0 or v != v


def fmod(a, b):
    """fmod jak w C: nieskończona dzielna daje nan (Python zgłasza błąd)."""
    if math.isinf(a) or a != a or b != b:
        return math.nan
    return math.fmod(a, b)


def fidiv(a, b):
    """a // b dla ułamków: iloraz obcięty w stronę zera (jak rt_fidiv)."""
    mod = fmod(a, b)
    div = (a - mod) / b
    if div != div:
        return div
    if div:
        return div if math.isinf(div) else float(round(div))
    return math.copysign(0.0, a / b)


def arith(op, a, b):
    both = isinstance(a, int) and isinstance(b, int)
    if op in ("/", "//", "%") and b == 0:
        raise FErr("div")
    if op == "+":
        return chk(a + b) if both else float(a) + float(b)
    if op == "-":
        return chk(a - b) if both else float(a) - float(b)
    if op == "*":
        return chk(a * b) if both else float(a) * float(b)
    if op == "/":
        return a / b if both else float(a) / float(b)
    if op == "//":
        if both:
            q = abs(a) // abs(b)
            return chk(q if (a < 0) == (b < 0) else -q)
        return fidiv(float(a), float(b))
    if both:
        m = abs(a) % abs(b)
        return m if a >= 0 else -m
    return fmod(float(a), float(b))


def compare(op, a, b):
    return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b, "==": a == b, "!=": a != b}[op]


def show(v):
    if isinstance(v, int):
        return str(v)
    if v != v:
        return "nan"
    return repr(v)


# wyrażenie: (tekst źródła, funkcja licząca w środowisku)
def expr(r, depth):
    c = r.randint(0, 11 if depth < 3 else 2)
    if c == 0:
        v = r.choice(INTS) if r.random() < 0.3 else r.randint(1, 9)
        return str(v), lambda env: v
    if c == 1:
        s = r.choice(FLTS)
        if s == "0.0" and r.random() < 0.7:
            s = "0.25"
        v = float(s)
        return s, lambda env: v
    if c == 2:
        n = r.choice(VARS)
        return n, lambda env: env[n]
    if c <= 7:
        op = r.choice(["+", "-", "*", "/", "//", "%"])
        a, fa = expr(r, depth + 1)
        if op in ("/", "//", "%") and r.random() < 0.6:   # zwykle niezerowy dzielnik
            b = r.choice(["3", "7", "2.5", "0.1", "1" + "0" * 30 + ".0", "(0 - 3)", "v3"])
            fb = (lambda env: env["v3"]) if b == "v3" else (lambda env, v=eval(b): v)
        else:
            b, fb = expr(r, depth + 1)
        return "(" + a + " " + op + " " + b + ")", lambda env: arith(op, fa(env), fb(env))
    if c == 8:
        k = r.choice([1, 1, 2])
        parts = [expr(r, depth + 1) for _ in range(k + 1)]
        ops = [r.choice(CMP) for _ in range(k)]
        src = "(" + parts[0][0] + "".join(" " + o + " " + p[0] for o, p in zip(ops, parts[1:])) + ")"

        def f(env):
            a = parts[0][1](env)
            for o, p in zip(ops, parts[1:]):
                b = p[1](env)
                if not compare(o, a, b):
                    return 0
                a = b
            return 1
        return src, f
    if c == 9:
        op = r.choice(["and", "or"])
        a, fa = expr(r, depth + 1)
        b, fb = expr(r, depth + 1)

        def f(env):
            x = truth(fa(env))
            if op == "and":
                return int(x and truth(fb(env)))
            return int(x or truth(fb(env)))
        return "(" + a + " " + op + " " + b + ")", f
    if c == 10 and r.random() < 0.5:
        return math_call(r, depth)
    if c == 10 and r.random() < 0.3:
        a, fa = expr(r, depth + 1)
        return "(not " + a + ")", lambda env: int(not truth(fa(env)))
    a, fa = expr(r, depth + 1)
    return "-" + a if a[0] in "(v" else "-(" + a + ")", lambda env: chk(-fa(env))


def math_call(r, depth):
    k = r.randint(0, 8)
    a, fa = expr(r, depth + 1)
    if k <= 3:
        name = ["floor", "ceil", "trunc", "round"][k]
        f = [math.floor, math.ceil, math.trunc, round][k]
        return "math.%s(%s)" % (name, a), lambda env: to_int(f, fa(env))
    if k == 4:
        return "math.sqrt(%s)" % a, lambda env: m_sqrt(fa(env))
    if k == 5:
        return "math.abs(%s)" % a, lambda env: m_abs(fa(env))
    if k == 6:
        n = r.randint(-3, 4)
        b, fb = (str(n), lambda env: n) if n >= 0 else ("-" + str(-n), lambda env: n)
        if r.random() < 0.2:
            b, fb = expr(r, depth + 1)
        return "math.round(%s, %s)" % (a, b), lambda env: m_round2(fa(env), fb(env))
    if k == 7:
        b, fb = expr(r, depth + 1) if r.random() < 0.5 else (str(r.randint(0, 5)), None)
        if fb is None:
            n = int(b)
            fb = lambda env: n
        return "math.pow(%s, %s)" % (a, b), lambda env: m_pow(fa(env), fb(env))
    op = r.choice(["min", "max"])
    rest = [expr(r, depth + 1) for _ in range(r.randint(1, 2))]
    src = "math.%s(%s)" % (op, ", ".join([a] + [x[0] for x in rest]))
    fs = [fa] + [x[1] for x in rest]
    return src, lambda env: m_minmax(op, [f(env) for f in fs])


def index(r):
    if r.random() < 0.5:
        i = r.randint(-6, 5)
        s, fi = (str(i), lambda env: i) if i >= 0 else ("-" + str(-i), lambda env: i)
    else:
        s, fi = expr(r, 2)

    def f(env):
        i = fi(env)
        if not isinstance(i, int):
            raise FErr("int")
        if not -len(TX) <= i < len(TX):
            raise FErr("idx")
        return TX[i]
    return "tx[" + s + "]", f


class Prog:
    def __init__(self, r):
        self.r = r
        self.lines = ['import math', 'tx = "' + TX + '"']
        self.init = {}
        for n in VARS:
            if r.random() < 0.5:
                v = r.choice(INTS[:7])
                self.lines.append("%s = %d" % (n, v))
            else:
                s = r.choice(FLTS[:9])
                v = float(s)
                self.lines.append("%s = %s" % (n, s))
            self.init[n] = v

    def add(self, text, indent):
        self.lines.append("  " * indent + text)
        return len(self.lines)

    # instrukcje: lista (linia, rodzaj, dane)
    def block(self, depth, indent, n):
        r = self.r
        body = []
        for _ in range(n):
            k = r.randint(0, 9 if depth < 2 else 6)
            if k <= 2:
                v = r.choice(VARS)
                s, f = expr(r, 0)
                body.append((self.add(v + " = " + s, indent), "set", (v, f)))
            elif k == 3:
                v = r.choice(VARS)
                op = r.choice(["+", "-", "*", "/", "//", "%"])
                s, f = expr(r, 1)
                body.append((self.add(v + " " + op + "= " + s, indent), "op", (v, op, f)))
            elif k == 4:
                s, f = expr(r, 0)
                body.append((self.add("print(" + s + ")", indent), "print", f))
            elif k == 5:
                s, f = expr(r, 1)
                if r.random() < 0.5:
                    body.append((self.add('print("x=" + ' + s + ")", indent), "pre", f))
                else:
                    body.append((self.add("print(" + s + ' + " y")', indent), "post", f))
            elif k == 6:
                s, f = index(r)
                body.append((self.add("print(" + s + ")", indent), "idx", f))
            elif k <= 8:
                s, f = expr(r, 1)
                ln = self.add("if " + s + " {", indent)
                yes = self.block(depth + 1, indent + 1, r.randint(1, 3))
                no = None
                if r.random() < 0.5:
                    self.add("} else {", indent)
                    no = self.block(depth + 1, indent + 1, r.randint(1, 3))
                self.add("}", indent)
                body.append((ln, "if", (f, yes, no)))
            else:
                c = "c%d" % depth
                cnt = r.randint(0, 4)
                body.append((self.add(c + " = 0", indent), "cset", c))
                ln = self.add("while %s < %d {" % (c, cnt), indent)
                inner = self.block(depth + 1, indent + 1, r.randint(1, 3))
                inc = self.add(c + " += 1", indent + 1)
                self.add("}", indent)
                body.append((ln, "while", (c, cnt, inner, inc)))
        return body

    def run(self, body, env, out):
        for ln, kind, d in body:
            self.line = ln
            if kind == "set":
                env[d[0]] = d[1](env)
            elif kind == "op":
                env[d[0]] = arith(d[1], env[d[0]], d[2](env))
            elif kind == "print":
                out.append(show(d(env)) + "\n")
            elif kind == "pre":
                out.append("x=" + show(d(env)) + "\n")
            elif kind == "post":
                out.append(show(d(env)) + " y\n")
            elif kind == "idx":
                out.append(d(env) + "\n")
            elif kind == "if":
                if truth(d[0](env)):
                    self.run(d[1], env, out)
                elif d[2]:
                    self.run(d[2], env, out)
            elif kind == "cset":
                env[d] = 0
            else:
                c, cnt, inner, inc = d
                while env[c] < cnt:
                    self.run(inner, env, out)
                    env[c] += 1


def program(r):
    p = Prog(r)
    body = p.block(0, 0, r.randint(1, 10))
    env = dict(p.init)
    out = []
    err = None
    try:
        p.run(body, env, out)
    except FErr as e:
        err = "fih: błąd w linii %d: %s\n" % (p.line, MSG[e.args[0]])
    return "\n".join(p.lines) + "\n", "".join(out), err


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
    print(f"ziarno {seed}: {n} programów z ułamkami, niezgodności: {bad}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
