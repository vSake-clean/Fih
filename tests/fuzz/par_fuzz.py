#!/usr/bin/env python3
"""Fuzzer trybu wielordzeniowego: duże programy (> 512 KB, więc dzielone na
kawałki) z błędem wstawionym w losowe miejsce albo bez błędu. Wynik musi być
identyczny z wyrocznią (fuzz.py) w obu trybach, na 1 i na wszystkich rdzeniach.

użycie: par_fuzz.py [liczba_programów] [ziarno]"""
import os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import oracle
sys.argv, args = sys.argv[:1], sys.argv[1:]
src = open(os.path.join(os.path.dirname(__file__), "fuzz.py")).read().replace("\nmain()\n", "\n")
exec(compile(src, "fuzz.py", "exec"))

count = int(args[0]) if args else 30
seed = int(args[1]) if len(args) > 1 else random.randrange(1 << 30)
r = random.Random(seed)
tmp = tempfile.mkdtemp()
prog, binp = os.path.join(tmp, "p.fh"), os.path.join(tmp, "p")
BAD = ['x = 1', 'if 1 {\n}', 'calc("1/0")', 'print("a\\qb")', 'calc("2 +")', 'pisz("x")', 'print("abc', 'calc("(1")', '5x("a")']
fails = 0
for i in range(count):
    lines = []
    size = r.randint(600_000, 3_000_000)
    total = 0
    while total < size:
        k = r.random()
        if k < 0.5: l = f'calc("{gen_expr(r)}")'
        elif k < 0.95: l = f'print("{gen_text(r)}")'
        else: l = r.choice(["# komentarz", "", "   ", "\t# x"])
        try:
            evaluate(l[6:-2].encode()) if l.startswith("calc") else None
        except FihError:
            continue                      # tylko poprawne linie
        lines.append(l); total += len(l) + 1
    if r.random() < 0.7:                  # błąd w losowym miejscu
        pos = r.choice([0, len(lines) - 1, r.randrange(len(lines)), len(lines) // 2, len(lines) // 2 + 1])
        lines.insert(pos, r.choice(BAD))
    data = ("\n".join(lines) + r.choice(["\n", ""])).encode()
    open(prog, "wb").write(data)
    exp_all = oracle.run(data)
    exp, kind = exp_all[:3], exp_all[3]
    for cpus in (["taskset", "-c", "0"], []):
        res = subprocess.run(cpus + [FIH, prog], capture_output=True)
        if (res.stdout, res.stderr, res.returncode) != exp:
            fails += 1; print(f"BŁĄD interpretacja #{i} cpus={cpus or 'wszystkie'}: kod {res.returncode} vs {exp[2]}, {res.stderr!r} vs {exp[1]!r}, stdout zgodny: {res.stdout == exp[0]}")
        if os.path.exists(binp): os.remove(binp)
        res = subprocess.run(cpus + [FIH, "build", prog, "-o", binp], capture_output=True)
        if kind == "static":
            ok = res.returncode == 1 and res.stderr == exp[1] and not os.path.exists(binp)
        else:
            run = subprocess.run([binp], capture_output=True)
            ok = res.returncode == 0 and (run.stdout, run.stderr, run.returncode) == exp
        if not ok:
            fails += 1; print(f"BŁĄD kompilacja #{i} cpus={cpus or 'wszystkie'}: kod {res.returncode}, {res.stderr!r}")
    if fails:
        open(os.path.join(os.path.dirname(__file__), f"par_fail_{seed}_{i}.fh"), "wb").write(data); break
print(f"ziarno {seed}: {count} dużych programów, niezgodności: {fails}")
sys.exit(1 if fails else 0)
