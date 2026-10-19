#!/usr/bin/env python3
"""Fuzzer Fih: losowe programy (poprawne i zepsute) porównywane z wyrocznią.

Programy mają tylko print i calc (składnia 0.1), więc wykonuje je głównie
szybki silnik interp.asm. Wyrocznia to niezależna implementacja języka
w Pythonie (oracle.py); porównanie obu trybów jak w fuzz2.py (check).
Każde zakończenie sygnałem (np. SIGSEGV) to błąd.

użycie: fuzz.py [liczba_programów] [ziarno]
"""
import os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import oracle
from fuzz2 import check

sys.setrecursionlimit(100000)
FIH = os.environ.get("FIH") or os.path.join(os.path.dirname(__file__), "..", "..", "fih")
I64_MIN, I64_MAX = -(1 << 63), (1 << 63) - 1
wrap = lambda v: (v + (1 << 63)) % (1 << 64) - (1 << 63)

MSG = {
    "char": "nieoczekiwany znak na początku instrukcji",
    "lparen": "oczekiwano '(' po nazwie instrukcji",
    "string": "oczekiwano napisu w cudzysłowie",
    "unterminated": "niezamknięty napis",
    "rparen": "oczekiwano ')' po napisie",
    "trailing": "nieoczekiwane znaki po instrukcji",
    "unknown": "nieznana instrukcja (znane: print, calc)",
    "escape": "nieznana sekwencja ucieczki (znane: \\n \\t \\\\ \\\")",
    "e_unexpected": "nieoczekiwany znak w wyrażeniu",
    "e_incomplete": "niekompletne wyrażenie",
    "e_rparen": "brak ')' w wyrażeniu",
    "e_div0": "dzielenie przez zero",
    "e_overflow": "liczba za duża (max 9223372036854775807)",
    "e_ovf": "przepełnienie: wynik poza zakresem liczb 64-bitowych",
}

class FihError(Exception):
    pass

def chk(v):
    if not I64_MIN <= v <= I64_MAX: raise FihError("e_ovf")
    return v

def evaluate(s: bytes) -> int:
    p = 0; n = len(s)
    def ws():
        nonlocal p
        while p < n and s[p] in b" \t": p += 1
    def expr():
        nonlocal p
        v = term()
        while True:
            ws()
            if p < n and s[p] in b"+-":
                op = s[p]; p += 1; r = term()
                v = chk(v + r if op == 43 else v - r)
            else:
                return v
    def term():
        nonlocal p
        v = unary()
        while True:
            ws()
            if p < n and s[p] in b"*/%":
                op = s[p]; p += 1; r = unary()
                if op == 42: v = chk(v * r); continue
                if r == 0: raise FihError("e_div0")
                if r == -1:
                    if op == 47: chk(-v)
                    q, m = -v, 0
                else:
                    q = abs(v) // abs(r) * (1 if (v < 0) == (r < 0) else -1)
                    m = v - q * r
                v = q if op == 47 else m
            else:
                return v
    def unary():
        # jak w Fih: ciąg znaków +/- liczy się jako parzystość minusów
        nonlocal p
        neg = 0
        while True:
            ws()
            if p >= n: raise FihError("e_incomplete")
            if s[p] == 45: p += 1; neg ^= 1; continue
            if s[p] == 43: p += 1; continue
            break
        v = primary()
        return chk(-v) if neg else v
    def primary():
        nonlocal p
        c = s[p]
        if c == 40:
            p += 1; v = expr(); ws()
            if p >= n or s[p] != 41: raise FihError("e_rparen")
            p += 1; return v
        if not 48 <= c <= 57: raise FihError("e_unexpected")
        v = 0
        while p < n and 48 <= s[p] <= 57:
            v = v * 10 + s[p] - 48
            if v > I64_MAX: raise FihError("e_overflow")
            p += 1
        return v
    v = expr(); ws()
    if p < n: raise FihError("e_unexpected")
    return v

def run_oracle(src: bytes):
    """-> (stdout, stderr, kod)"""
    return oracle.run(src)[:3]

# ---------- generator ----------
def gen_number(r):
    if r.random() < 0.9:  # zwykle liczby bez ryzyka przepełnienia i zera
        return str(r.choice([r.randint(1, 9), r.randint(1, 10**6), r.randint(1, 3 * 10**9)]))
    return r.choice([str(r.randint(0, 9)), str(r.randint(0, 10**6)), str(r.randint(0, I64_MAX)),
                     str(I64_MAX), "9223372036854775808", "0", "00012", str(r.randint(0, 10**30))])

def gen_expr(r, d=0):
    k = r.random()
    if d > 5 or k < 0.35: e = gen_number(r)
    elif k < 0.45: e = "(" + gen_expr(r, d + 1) + ")"
    elif k < 0.55: e = r.choice("-+") + gen_expr(r, d + 1)
    else: e = gen_expr(r, d + 1) + r.choice(["+", "-", "*", "/", "%", " + ", " * ", "/", "%"]) + gen_expr(r, d + 1)
    if r.random() < 0.1: e = r.choice([" ", "\t", "  "]) + e + r.choice([" ", ""])
    return e

def mutate(r, s, rate):
    if not s or r.random() >= rate: return s
    i = r.randrange(len(s) + 1)
    k = r.random()
    junk = r.choice(list("()+-*/%\"\\#x 0\t\r\n_aZ\x00\xff") + ["print", "calc", "ł"])
    if k < 0.4: return s[:i] + junk + s[i:]
    if k < 0.7: return s[:i] + s[i + 1:]
    return s[:i] + junk + s[i + 1:]

def gen_text(r):
    parts = []
    for _ in range(r.randint(0, 8)):
        parts.append(r.choice(["ryba", " ", "2 + 3", "zażółć", "🐟", "\\n", "\\t", "\\\\", '\\"', "#", "calc(", ")"]))
    return "".join(parts)

def gen_line(r, rate):
    k = r.random() if rate else r.random() * 0.85
    if k < 0.4: line = f'calc("{gen_expr(r)}")'
    elif k < 0.75: line = f'print("{gen_text(r)}")'
    elif k < 0.85: line = "# " + gen_text(r)
    elif k < 0.9: line = ""
    else: line = r.choice(["pisz", "Print", "calc", "_x1", "print"]) + r.choice(["(", " (", "", "(  "]) + r.choice(['"', "", "'"]) + gen_text(r) + r.choice(['"', ""]) + r.choice([")", "", ") x", ")  # k"])
    if r.random() < 0.15: line = r.choice([" ", "\t", "  \t"]) + line
    if r.random() < 0.1: line += r.choice(["   ", " # komentarz", "\r", "\t#"])
    return mutate(r, line, rate)

def gen_program(r):
    rate = r.choice([0, 0, 0.02, 0.1, 0.4])   # część programów bez mutacji
    lines = [gen_line(r, rate) for _ in range(r.randint(0, 25))]
    src = "\n".join(lines) + r.choice(["\n", "", "\n\n", "\r\n"])
    return src.encode("utf-8", "surrogatepass")

def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 30)
    r = random.Random(seed)
    tmp = tempfile.mkdtemp()
    failures = 0
    stats = {"ok": 0, "err": 0}
    for i in range(count):
        src = gen_program(r)
        stats["ok" if oracle.run(src)[2] == 0 else "err"] += 1
        problems = check(src, tmp)
        if problems:
            failures += 1
            path = os.path.join(os.path.dirname(__file__), f"fail_{seed}_{i}.fh")
            open(path, "wb").write(src)
            print(f"BŁĄD #{i} (zapisano {path}):\n  " + "\n  ".join(problems))
            if failures >= 10: break
    print(f"ziarno {seed}: {count} programów ({stats['ok']} poprawnych, {stats['err']} z błędem), niezgodności: {failures}")
    sys.exit(1 if failures else 0)

main()
