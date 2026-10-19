#!/usr/bin/env python3
"""Porównanie odporności: te same złośliwe przypadki w wielu językach.

Przypadek zaliczony, gdy program nie kończy się awarią (sygnałem, w tym awarią
kompilatora) ani zawieszeniem — a w przypadkach oznaczonych "kod" dodatkowo
nie zgłasza sukcesu (kod 0) mimo błędu albo utraty wyjścia; w przypadkach
"wynik" wypisuje dokładny wynik albo zgłasza błąd (kod != 0) — cicho zła
liczba się nie liczy.
Wynik: bench/stability.csv (case,lang,ok,kod)."""
import os, random, resource, shutil, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIH = os.path.join(ROOT, "fih")
T = tempfile.mkdtemp()
D, M = 200_000, 3000

# program "wypisz wyrażenie E" w każdym języku
def src(lang, e, rep=1):
    return {
        "Fih": f'calc("{e}")\n' * rep, "Fih (build)": f'calc("{e}")\n' * rep,
        "C": "#include <stdio.h>\nint main(){" + f'for(int i=0;i<{rep};i++) printf("%lld\\n", (long long)({e}));' + "return 0;}\n",
        "C++": "#include <iostream>\nint main(){" + f"for(int i=0;i<{rep};i++) std::cout << (long long)({e}) << '\\n';" + "return 0;}\n",
        "Python": f"for _ in range({rep}): print({e.replace('/', '//')})\n",
        "Node.js": f"for (let i = 0; i < {rep}; i++) console.log(Math.trunc({e}));\n",
        "Perl": f"print(int({e}), \"\\n\") for 1..{rep};\n",
        "Lua": f"for i = 1, {rep} do print(({e.replace('/', '//')})) end\n",
        "bc": f"for (i = 0; i < {rep}; i++) {{ ({e}) }}\nquit\n" if rep > 1 else f"{e}\nquit\n",
    }[lang]

def strsrc(lang, s):
    return {
        "Fih": f'print("{s}")\n', "Fih (build)": f'print("{s}")\n',
        "C": '#include <stdio.h>\nint main(){puts("' + s + '");return 0;}\n',
        "C++": '#include <iostream>\nint main(){std::cout << "' + s + '" << "\\n";return 0;}\n',
        "Python": f'print("{s}")\n', "Node.js": f'console.log("{s}");\n',
        "Perl": f'print("{s}\\n");\n', "Lua": f'print("{s}")\n', "bc": f'"{s}\n"\nquit\n',
    }[lang]

EXT = {"Fih": "fh", "Fih (build)": "fh", "C": "c", "C++": "cpp", "Python": "py", "Node.js": "js", "Perl": "pl", "Lua": "lua", "bc": "bc"}
LANGS = ["Fih", "Fih (build)", "C", "C++", "Python", "Node.js", "Perl", "Lua", "bc"]

def prepare(lang, code, name):
    """-> (polecenie do uruchomienia albo None, kod porażki przygotowania)"""
    p = os.path.join(T, f"{name}.{EXT[lang]}")
    open(p, "w" if isinstance(code, str) else "wb").write(code)
    exe = os.path.join(T, name + "_" + EXT[lang] + "_bin")
    if lang in ("C", "C++"):
        try:
            r = subprocess.run(["gcc" if lang == "C" else "g++", "-O1", "-w", "-o", exe, p], capture_output=True, timeout=120, preexec_fn=LIMIT[0])
        except subprocess.TimeoutExpired:
            return None, HANG
        if b"internal compiler error" in r.stderr or r.returncode < 0: return None, ICE
        if r.returncode: return None, r.returncode     # zwykły błąd kompilacji — obsłużony
        return [exe], 0
    if lang == "Fih (build)":
        r = subprocess.run([FIH, "build", p, "-o", exe], capture_output=True, timeout=600, preexec_fn=LIMIT[0])
        if r.returncode: return None, r.returncode if r.returncode > 0 else SIG - r.returncode
        return [exe], 0
    cmd = {"Fih": [FIH], "Python": ["/usr/bin/python3"], "Node.js": ["node"], "Perl": ["perl"], "Lua": ["lua5.4"], "bc": ["bc", "-q"]}[lang]
    return cmd + [p], 0

LIMIT = [None]
SIG, ICE, HANG = 1000, 2000, 3000   # kody umowne: SIG + numer sygnału, awaria kompilatora, zawieszenie
def run(cmd, stdout=subprocess.DEVNULL, stack=None, close_stdout=False, mem=None):
    def pre():
        if stack: resource.setrlimit(resource.RLIMIT_STACK, (stack, stack))
        if mem: resource.setrlimit(resource.RLIMIT_AS, (mem, mem))
        if close_stdout: os.close(1)
    r = subprocess.run(cmd, stdout=None if close_stdout else stdout, stderr=subprocess.DEVNULL, timeout=600, preexec_fn=pre)
    return r.returncode if r.returncode >= 0 else SIG - r.returncode

rnd = random.Random(1)
garbage = bytes(rnd.randrange(256) for _ in range(4000))
CASES = [  # id, opis, generator kodu, sposób uruchomienia, tryb ("awaria" albo "kod")
    ("deep", "200 tys. zagnieżdżonych nawiasów", lambda l: src(l, "(" * D + "1" + ")" * D), "normal", "awaria"),
    ("deep2m", "2 mln zagnieżdżonych nawiasów", lambda l: src(l, "(" * 2_000_000 + "1" + ")" * 2_000_000), "normal", "awaria"),
    ("stack", "mały stos + 3000 nawiasów", lambda l: src(l, "(" * M + "1" + ")" * M), "stack", "awaria"),
    ("div", "dzielenie przez zero", lambda l: src(l, "7 / (3 - 3)") if l not in ("C", "C++") else src(l, "7 / (volatile int){3 - 3}" if l == "C" else "7 / (int)(std::rand() * 0)"), "normal", "kod"),
    ("full", "zapis na pełny dysk", lambda l: src(l, "6 * 7", 2000), "full", "kod"),
    ("closed", "zamknięte stdout", lambda l: src(l, "6 * 7", 2000), "closed", "kod"),
    ("garbage", "losowe bajty jako kod", lambda l: garbage, "normal", "awaria"),
    ("bignum", "liczba o 500 cyfrach", lambda l: src(l, "9" * 500 + " + 1"), "normal", "awaria"),
    ("longline", "napis 20 MB", lambda l: strsrc(l, "ryba" * 5_000_000), "normal", "awaria"),
    ("overflow", "9223372036854775807 + 1", lambda l: src(l, "9223372036854775807 + 1"), "capture:9223372036854775808", "wynik"),
    ("overflow3", "9223372036854775807 * 3", lambda l: src(l, "9223372036854775807 * 3"), "capture:27670116110564327421", "wynik"),
    ("memlimit", "limit pamięci 300 MB + napis 20 MB", lambda l: strsrc(l, "ryba" * 5_000_000), "mem", "awaria"),
]

rows = []
for cid, desc, gen, how, mode in CASES:
    for lang in LANGS:
        stack = 256 * 1024 if how == "stack" else None
        mem = 300 << 20 if how == "mem" else None
        def limit(stack=stack, mem=mem):
            if stack: resource.setrlimit(resource.RLIMIT_STACK, (stack, stack))
            if mem: resource.setrlimit(resource.RLIMIT_AS, (mem, mem))
        LIMIT[0] = limit
        try:
            cmd, code = prepare(lang, gen(lang), f"{cid}")
            if cmd is not None:
                if how == "full":
                    with open("/dev/full", "wb") as f: code = run(cmd, stdout=f)
                elif how == "closed":
                    code = run(cmd, close_stdout=True)
                elif how.startswith("capture:"):
                    r = subprocess.run(cmd, capture_output=True, timeout=600)
                    code = r.returncode if r.returncode >= 0 else SIG - r.returncode
                    if code == 0 and r.stdout.strip() != how.split(":")[1].encode():
                        code = 4000   # cicho zły wynik
                else:
                    code = run(cmd, stack=stack, mem=mem)
        except subprocess.TimeoutExpired:
            code = HANG
        ok = code < SIG and (mode == "awaria" or code != 0 or (mode == "wynik" and code == 0))
        rows.append((cid, lang, int(ok), code))
        what = "sygnał %d" % (code - SIG) if SIG < code < ICE else "awaria kompilatora" if code == ICE else "zawieszenie" if code == HANG else "cicho zły wynik" if code == 4000 else "kod %d" % code
        print(f"  {desc:34s} {lang:12s} {'OK ' if ok else 'BŁĄD'} ({what})", flush=True)

with open(os.path.join(ROOT, "bench", "stability.csv"), "w") as f:
    f.write("case,lang,ok,kod\n")
    for r in rows: f.write(",".join(map(str, r)) + "\n")
print()
for lang in LANGS:
    print(f"  {lang:12s} {sum(r[2] for r in rows if r[1] == lang)}/{len(CASES)}")
shutil.rmtree(T)
