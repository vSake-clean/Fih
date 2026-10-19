#!/usr/bin/env python3
"""Fuzzer Fih 0.2: losowe programy ze zmiennymi, if/else, while, break/continue,
porównaniami i operatorami logicznymi, porównywane z wyrocznią (oracle.py).

Dla każdego programu sprawdzamy oba tryby:
  interpretacja: stdout, stderr i kod wyjścia jak w wyroczni,
  kompilacja:    błąd wykryty przed uruchomieniem -> ten sam komunikat i brak
                 pliku wynikowego; inaczej skompilowany plik daje to samo co wyrocznia.
Każde zakończenie sygnałem to błąd. Programy liczące zbyt długo są pomijane.

użycie: fuzz2.py [liczba_programów] [ziarno]
"""
import os, random, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(__file__))
import oracle

FIH = os.environ.get("FIH") or os.path.join(os.path.dirname(__file__), "..", "..", "fih")
VARS = ["a", "b", "c", "x", "y", "i", "n", "suma", "_t", "licznik", "Z9"]
I64 = (1 << 63) - 1


def gen_number(r):
    k = r.random()
    if k < 0.75: return str(r.randint(0, 20))
    if k < 0.9: return str(r.randint(0, 10 ** 6))
    if r.random() < 0.05: return "9223372036854775808"
    return r.choice([str(I64), "4294967296", "0", "007", str(r.randint(0, I64))])


class Gen:
    def __init__(self, r, rate):
        self.r, self.rate = r, rate
        self.known = set()          # zmienne już przypisane (zwykle) w tekście
        self.loop_vars = []

    def var(self, read=True):
        r = self.r
        if read:
            if self.known and r.random() < 0.98: return r.choice(sorted(self.known))
            if not self.known or r.random() < 0.5: return gen_number(r)
        return r.choice(VARS)

    def atom(self):
        r = self.r
        k = r.random()
        if k < 0.45: return gen_number(r)
        if k < 0.85: return self.var()
        return r.choice(["-", "+", "--", "- "]) + self.atom()

    def expr(self, d=0, level=0):
        """level: 0 = dowolne wyrażenie, 1 = bez and/or/not na górze,
        2 = tylko arytmetyka (operand porównania)"""
        r = self.r
        k = r.random()
        if d > 4 or k < 0.3: return self.atom()
        if k < 0.4: return "(" + self.expr(d + 1) + ")"
        if k < 0.7 or level == 2:
            return self.expr(d + 1, 2) + r.choice([" + ", " - ", " * ", " / ", " % ", "+", "*", "-"]) + self.expr(d + 1, 2)
        if k < 0.85 or level == 1:
            e = self.expr(d + 1, 2)
            for _ in range(r.choice([1, 1, 1, 2, 3])):
                e += r.choice([" == ", " != ", " < ", " <= ", " > ", " >= ", "<", "=="]) + self.expr(d + 1, 2)
            return e
        if k < 0.95: return self.expr(d + 1) + r.choice([" and ", " or "]) + self.expr(d + 1)
        return r.choice(["not ", "not not ", "not  "]) + self.expr(d + 1, 1)

    def cond(self):
        r = self.r
        if r.random() < 0.6:
            return self.expr(2, 2) + r.choice([" < ", " == ", " != ", " >= "]) + self.expr(2, 2)
        return self.expr()

    def block(self, depth, lines, n, in_loop):
        for _ in range(n):
            self.stmt(depth, lines, in_loop)

    def stmt(self, depth, lines, in_loop):
        r = self.r
        ind = "    " * depth
        k = r.random()
        if k < 0.3:
            v = self.var(read=False)
            if v in self.known and r.random() < 0.4:
                lines.append(f"{ind}{v} {r.choice(['+', '-', '*', '/', '%'])}= {self.expr()}")
            else:
                lines.append(f"{ind}{v} = {self.expr()}")
                self.known.add(v)
        elif k < 0.45:
            e = self.expr()
            lines.append(f'{ind}calc("{e}")' if r.random() < 0.3 else f"{ind}calc({e})")
        elif k < 0.52:
            lines.append(f'{ind}print("{r.choice(["ryba", "", "a b", "zażółć 🐟", "x\\ty", "\\\"q\\\"", "#"])}")')
        elif k < 0.7 and depth < 4:
            lines.append(f"{ind}if {self.cond()} {{")
            self.block(depth + 1, lines, r.randint(0, 3), in_loop)
            for _ in range(r.choice([0, 0, 1, 2])):
                lines.append(f"{ind}}} else if {self.cond()} {{")
                self.block(depth + 1, lines, r.randint(0, 2), in_loop)
            if r.random() < 0.4:
                lines.append(f"{ind}}} else {{")
                self.block(depth + 1, lines, r.randint(0, 2), in_loop)
            lines.append(f"{ind}}}")
        elif k < 0.85 and depth < 3:
            # pętla z licznikiem — zwykle się kończy
            v = "k" + str(depth) + r.choice(["", "x"])
            lines.append(f"{ind}{v} = 0")
            self.known.add(v)
            lines.append(f"{ind}while {v} < {r.randint(0, 6)} {{")
            lines.append(f"{ind}    {v} += 1")
            self.block(depth + 1, lines, r.randint(0, 3), True)
            lines.append(f"{ind}}}")
        elif k < 0.92 and in_loop:
            lines.append(ind + r.choice(["break", "continue", "if " + self.cond() + " {\n" + ind + "    break\n" + ind + "}"]))
        else:
            lines.append(ind + r.choice(["# komentarz", "", "   ", "calc(" + self.expr() + ")  # k"]))

    def program(self):
        lines = []
        self.block(0, lines, self.r.randint(1, 12), False)
        return lines


def mutate(r, s):
    i = r.randrange(len(s) + 1)
    junk = r.choice(list("(){}+-*/%=<>!\"\\#x 0\t\r\n_aZ\x00\xff") +
                    ["print", "calc", "if", "else", "while", "break", "and", "or", "not", "==", "+=", "ł"])
    k = r.random()
    if k < 0.4: return s[:i] + junk + s[i:]
    if k < 0.7: return s[:i] + s[i + 1:]
    return s[:i] + junk + s[i + 1:]


def gen_program(r):
    rate = r.choice([0, 0, 0, 0.01, 0.05, 0.3])
    lines = Gen(r, rate).program()
    lines = [mutate(r, l) if rate and r.random() < rate * 3 else l for l in lines]
    src = "\n".join(lines) + r.choice(["\n", "", "\n\n", "\r\n"])
    return src.encode("utf-8", "surrogatepass")


def check(src, tmp):
    """-> lista problemów (pusta = zgodność) albo None (program pominięty)"""
    try:
        exp_out, exp_err, exp_code, kind = oracle.run(src, steps=200_000)
    except oracle.Steps:
        return None
    prog, binp = os.path.join(tmp, "p.fh"), os.path.join(tmp, "p")
    open(prog, "wb").write(src)
    problems = []
    res = subprocess.run([FIH, prog], capture_output=True, timeout=20)
    if res.returncode < 0:
        problems.append(f"interpretacja: sygnał {-res.returncode}")
    elif (res.stdout, res.stderr, res.returncode) != (exp_out, exp_err, exp_code):
        problems.append(f"interpretacja: kod {res.returncode} (oczekiwano {exp_code}), stderr {res.stderr!r} "
                        f"(oczekiwano {exp_err!r}), stdout zgodny: {res.stdout == exp_out}")
    if os.path.exists(binp): os.remove(binp)
    res = subprocess.run([FIH, "build", prog, "-o", binp], capture_output=True, timeout=20)
    if res.returncode < 0:
        problems.append(f"kompilacja: sygnał {-res.returncode}")
    elif kind == "static":
        if (res.stderr, res.returncode) != (exp_err, 1) or res.stdout or os.path.exists(binp):
            problems.append(f"kompilacja: kod {res.returncode}, stderr {res.stderr!r}, plik powstał: {os.path.exists(binp)}")
    elif res.returncode or res.stderr or res.stdout:
        problems.append(f"kompilacja: kod {res.returncode}, stderr {res.stderr!r}")
    else:
        run = subprocess.run([binp], capture_output=True, timeout=20)
        if (run.stdout, run.stderr, run.returncode) != (exp_out, exp_err, exp_code):
            problems.append(f"skompilowany program: kod {run.returncode} (oczekiwano {exp_code}), "
                            f"stderr {run.stderr!r}, stdout zgodny: {run.stdout == exp_out}")
    return problems


def main():
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 2000
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 30)
    r = random.Random(seed)
    tmp = tempfile.mkdtemp()
    failures = 0
    stats = {None: 0, "static": 0, "runtime": 0, "skip": 0}
    for i in range(count):
        src = gen_program(r)
        problems = check(src, tmp)
        if problems is None:
            stats["skip"] += 1
            continue
        stats[oracle.run(src, steps=200_000)[3]] += 1
        if problems:
            failures += 1
            path = os.path.join(os.path.dirname(__file__), f"fail2_{seed}_{i}.fh")
            open(path, "wb").write(src)
            print(f"BŁĄD #{i} (zapisano {path}):\n  " + "\n  ".join(problems))
            if failures >= 10: break
    print(f"ziarno {seed}: {count} programów (poprawne {stats[None]}, błąd składni {stats['static']}, "
          f"błąd w trakcie {stats['runtime']}, pominięte {stats['skip']}), niezgodności: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
