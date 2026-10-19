#!/usr/bin/env python3
"""Zbiera wyniki hyperfine do bench/results.json i rysuje wykresy kolumnowe
w terminalu. Zasada: im wyższa kolumna, tym lepiej."""
import json, sys, os, platform

n, out = int(sys.argv[1]), sys.argv[2]
load = lambda f: {r["command"]: r["mean"] for r in json.load(open(f"{out}/{f}"))["results"]}
exec_t, comp_t, hello_t = load("exec.json"), load("compile.json"), load("hello.json")
comp_t.update(load("compile_fih.json"))
exec1_t = load("exec1.json")
loops_t = load("loops.json")
PRIMES = 300_000 - 2       # liczby sprawdzane w bench/primes
langs = ["Fih", "Fih (build)", "C", "C++", "Python"]

charts = [
    {"id": "exec", "title": "Wykonanie gotowego programu", "unit": "linii/s",
     "note": f"program {n} linii (print + calc); Fih (build), C, C++ już skompilowane",
     "values": {l: n / exec_t[l] for l in langs}},
    {"id": "source", "title": "Od kodu źródłowego do wyniku", "unit": "linii/s",
     "note": "kompilacja (fih build / gcc -O2 / g++ -O2) + wykonanie",
     "values": {l: n / (exec_t[l] + comp_t.get(l, 0)) for l in langs}},
    {"id": "startup", "title": "Start programu (Hello World)", "unit": "uruchomień/s",
     "note": "ile razy na sekundę da się uruchomić Hello World",
     "values": {l: 1 / hello_t[l] for l in langs}},
    {"id": "loops", "title": "Pętle: liczby pierwsze", "unit": "liczb/s",
     "note": "liczby < 300 000 sprawdzane dzieleniem próbnym (while, if, %, break)",
     "values": {l: PRIMES / loops_t[l] for l in langs}},
]
cpu = next((l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name")), "?")
json.dump({"n": n, "cpu": cpu, "charts": charts}, open("bench/results.json", "w"), indent=2, ensure_ascii=False)
single = {"id": "exec1", "title": "Wykonanie na jednym rdzeniu", "unit": "linii/s",
          "note": "taskset -c 0: interpretowany Fih vs skompilowane C",
          "values": {l: n / exec1_t[l] for l in ("Fih", "C")}}
times = {"exec": exec_t, "source": {l: exec_t[l] + comp_t.get(l, 0) for l in langs}, "startup": hello_t,
         "loops": loops_t}
with open("bench/results.csv", "w") as fh:
    fh.write("test,lang,value,unit,ms\n")
    for ch in charts:
        for l in langs:
            fh.write(f"{ch['id']},{l},{ch['values'][l]:.1f},{ch['unit']},{times[ch['id']][l] * 1000:.3f}\n")
    for l in ("Fih", "C"):
        fh.write(f"exec1,{l},{single['values'][l]:.1f},linii/s,{exec1_t[l] * 1000:.3f}\n")

def fmt(v):
    for div, suf in ((1e9, "G"), (1e6, "M"), (1e3, "k")):
        if v >= div: return f"{v / div:.1f}{suf}"
    return f"{v:.0f}"

H, W = 12, 13
for ch in charts:
    vals = ch["values"]; top = max(vals.values())
    print(f"\n  {ch['title']} [{ch['unit']}] — wyżej = lepiej\n  ({ch['note']})\n")
    heights = {l: max(1, round(v / top * H)) for l, v in vals.items()}
    for row in range(H + 1, 0, -1):
        cells = []
        for l in langs:
            if heights[l] == row - 1:
                cells.append(fmt(vals[l]).center(W))
            elif heights[l] >= row:
                cells.append(("█" * (W - 3)).center(W))
            else:
                cells.append(" " * W)
        print("  " + "".join(cells))
    print("  " + "─" * (W * len(langs)))
    print("  " + "".join(l.center(W) for l in langs))
    best = max(vals, key=vals.get)
    print(f"  najlepszy: {best} ({fmt(vals[best])} {ch['unit']})")
print(f"\n  {single['title']}: " + ", ".join(f"{l} {fmt(v)} {single['unit']}" for l, v in single["values"].items()))
print("\nzapisano bench/results.json")
