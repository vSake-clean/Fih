#!/usr/bin/env python3
"""Fuzzer Fih: losowe programy (poprawne i zepsute) porównywane z wyrocznią.

Wyrocznia to niezależna implementacja języka w Pythonie. Dla każdego
programu sprawdzamy oba tryby:
  interpretacja: stdout, stderr i kod wyjścia muszą być identyczne,
  kompilacja:    przy błędzie ten sam komunikat i brak pliku wynikowego,
                 inaczej skompilowany plik daje pełne oczekiwane wyjście.
Każde zakończenie sygnałem (np. SIGSEGV) to błąd.

użycie: fuzz.py [liczba_programów] [ziarno]
"""
import os, random, subprocess, sys, tempfile

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
    out = bytearray(); p = 0; n = len(src); line = 1
    def blank():
        nonlocal p
        while p < n and src[p] in b" \t\r": p += 1
    try:
        while True:
            blank()
            if p >= n: break
            c = src[p]
            if c == 10: p += 1; line += 1; continue
            if c == 35:
                while p < n and src[p] != 10: p += 1
                continue
            start = p
            if 48 <= c <= 57: raise FihError("char")
            while p < n and (src[p] == 95 or 48 <= src[p] <= 57 or 97 <= (src[p] | 32) <= 122): p += 1
            name = src[start:p]
            if not name: raise FihError("char")
            blank()
            if p >= n or src[p] != 40: raise FihError("lparen")
            p += 1; blank()
            if p >= n or src[p] != 34: raise FihError("string")
            p += 1; s0 = p
            while True:
                if p >= n or src[p] == 10: raise FihError("unterminated")
                ch = src[p]
                if ch == 34: break
                p += 1
                if ch == 92:
                    if p >= n or src[p] == 10: raise FihError("unterminated")
                    p += 1
            body = src[s0:p]; p += 1
            blank()
            if p >= n or src[p] != 41: raise FihError("rparen")
            p += 1; blank()
            if p < n and src[p] not in b"\n#": raise FihError("trailing")
            if name == b"print":
                i = 0
                while i < len(body):
                    if body[i] == 92:
                        e = body[i + 1]
                        if e == 110: out += b"\n"
                        elif e == 116: out += b"\t"
                        elif e in b'\\"': out.append(e)
                        else: raise FihError("escape")
                        i += 2
                    else:
                        out.append(body[i]); i += 1
                out += b"\n"
            elif name == b"calc":
                out += str(evaluate(body)).encode() + b"\n"
            else:
                raise FihError("unknown")
    except FihError as e:
        return bytes(out), f"fih: błąd w linii {line}: {MSG[e.args[0]]}\n".encode(), 1
    return bytes(out), b"", 0

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
    prog, binp = os.path.join(tmp, "p.fh"), os.path.join(tmp, "p")
    failures = 0
    stats = {"ok": 0, "err": 0}
    for i in range(count):
        src = gen_program(r)
        exp_out, exp_err, exp_code = run_oracle(src)
        stats["ok" if exp_code == 0 else "err"] += 1
        open(prog, "wb").write(src)
        problems = []
        res = subprocess.run([FIH, prog], capture_output=True, timeout=10)
        if res.returncode < 0: problems.append(f"interpretacja: sygnał {-res.returncode}")
        elif (res.stdout, res.stderr, res.returncode) != (exp_out, exp_err, exp_code):
            problems.append(f"interpretacja: kod {res.returncode} (oczekiwano {exp_code}), stderr {res.stderr!r} (oczekiwano {exp_err!r}), stdout zgodny: {res.stdout == exp_out}")
        if os.path.exists(binp): os.remove(binp)
        res = subprocess.run([FIH, "build", prog, "-o", binp], capture_output=True, timeout=10)
        if res.returncode < 0: problems.append(f"kompilacja: sygnał {-res.returncode}")
        elif exp_code:
            if (res.stderr, res.returncode) != (exp_err, 1) or res.stdout or os.path.exists(binp):
                problems.append(f"kompilacja: kod {res.returncode}, stderr {res.stderr!r}, plik powstał: {os.path.exists(binp)}")
        else:
            if res.returncode or res.stderr or res.stdout:
                problems.append(f"kompilacja: kod {res.returncode}, stderr {res.stderr!r}")
            else:
                run = subprocess.run([binp], capture_output=True, timeout=10)
                if (run.stdout, run.stderr, run.returncode) != (exp_out, b"", 0):
                    problems.append(f"skompilowany program: kod {run.returncode}, stdout zgodny: {run.stdout == exp_out}")
        if problems:
            failures += 1
            path = os.path.join(os.path.dirname(__file__), f"fail_{seed}_{i}.fh")
            open(path, "wb").write(src)
            print(f"BŁĄD #{i} (zapisano {path}):\n  " + "\n  ".join(problems))
            if failures >= 10: break
    print(f"ziarno {seed}: {count} programów ({stats['ok']} poprawnych, {stats['err']} z błędem), niezgodności: {failures}")
    sys.exit(1 if failures else 0)

main()
