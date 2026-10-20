#!/usr/bin/env python3
"""Generuje ten sam program testowy w Fih, Pythonie, C i C++.

Program ma N linii: na przemian print("tekst") i calc("wyrażenie").
Operandy / i % są dodatnie, więc wyniki są identyczne we wszystkich
językach (Python // i % różnią się od C tylko dla liczb ujemnych).
"""
import random, sys, os

n = int(sys.argv[1]) if len(sys.argv) > 1 else 100_000
out = sys.argv[2] if len(sys.argv) > 2 else "bench/out"
os.makedirs(out, exist_ok=True)
rnd = random.Random(42)

lines = []  # (rodzaj, tekst)
for i in range(n):
    if i % 2 == 0:
        lines.append(("print", f"linia {i}: ryba numer {rnd.randint(1, 10**6)} plywa"))
    else:
        a, b, c, d, e, f = (rnd.randint(1, 10**4) for _ in range(6))
        lines.append(("calc", f"({a} + {b}) * {c} - {d} / {e} % {f} + -{a} * ({b} - {c})"))

def py_expr(x):
    return x.replace("/", "//")

CHUNK = 500  # C/C++: dzielimy na funkcje, żeby gcc nie mielił jednej gigantycznej

with open(f"{out}/program.fh", "w") as fh:
    for kind, t in lines:
        fh.write(f'{kind}("{t if kind == "print" else py_expr(t)}")\n')

with open(f"{out}/program.py", "w") as fh:
    for kind, t in lines:
        fh.write(f'print("{t}")\n' if kind == "print" else f"print({py_expr(t)})\n")

def c_like(path, header, emit_print, emit_calc, main_pre):
    with open(path, "w") as fh:
        fh.write(header)
        chunks = [lines[i:i + CHUNK] for i in range(0, len(lines), CHUNK)]
        for k, ch in enumerate(chunks):
            fh.write(f"static void part{k}(void) {{\n")
            for kind, t in ch:
                fh.write(emit_print(t) if kind == "print" else emit_calc(t))
            fh.write("}\n")
        fh.write("int main(void) {\n" + main_pre)
        for k in range(len(chunks)):
            fh.write(f"    part{k}();\n")
        fh.write("    return 0;\n}\n")

c_like(f"{out}/program.c", "#include <stdio.h>\n",
       lambda t: f'    puts("{t}");\n',
       lambda t: f'    printf("%lld\\n", (long long)(0LL + {t}));\n',
       "")
c_like(f"{out}/program.cpp", "#include <iostream>\n",
       lambda t: f'    std::cout << "{t}" << \'\\n\';\n',
       lambda t: f"    std::cout << (0LL + {t}) << '\\n';\n",
       "    std::ios::sync_with_stdio(false);\n")

# Hello World — mierzy start programu
os.makedirs(f"{out}/hello", exist_ok=True)
open(f"{out}/hello/hello.fh", "w").write('print("Hello, World!")\n')
open(f"{out}/hello/hello.py", "w").write('print("Hello, World!")\n')
open(f"{out}/hello/hello.c", "w").write('#include <stdio.h>\nint main(void){puts("Hello, World!");return 0;}\n')
open(f"{out}/hello/hello.cpp", "w").write('#include <iostream>\nint main(){std::cout<<"Hello, World!\\n";return 0;}\n')
print(f"wygenerowano {n} linii w {out}/")
