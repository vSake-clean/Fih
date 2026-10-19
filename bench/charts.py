#!/usr/bin/env python3
"""Rysuje wykresy kolumnowe SVG do docs/ z bench/results.csv i bench/stability.csv.
Zasada: im wyższa kolumna, tym lepiej."""
import csv, math, os
from collections import defaultdict

os.makedirs("docs", exist_ok=True)
W, H, TOP, BOT, LEFT, RIGHT = 760, 360, 64, 64, 16, 16
STYLE = """<style>
text{font-family:-apple-system,'Segoe UI',Helvetica,Arial,sans-serif;fill:#24292f}
.t{font-size:18px;font-weight:600}.s{font-size:12px;fill:#57606a}.v{font-size:13px;font-weight:600}
.l{font-size:13px}.g{stroke:#d0d7de}.b{fill:#8c959f}.f{fill:#1f6feb}
@media (prefers-color-scheme:dark){text{fill:#e6edf3}.s{fill:#8b949e}.g{stroke:#30363d}.b{fill:#6e7681}.f{fill:#4493f8}}
</style>"""


def fmt(v):
    for d, suf in ((1e9, " mld"), (1e6, " mln"), (1e3, " tys.")):
        if v >= d:
            return f"{v / d:.1f}".replace(".", ",") + suf
    return f"{v:.0f}"


def chart(name, title, sub, data, log, label=fmt, vmax=None):
    n = len(data)
    pw, ph = W - LEFT - RIGHT, H - TOP - BOT
    slot = pw / n
    bw = min(64, slot * 0.6)
    if log:
        lo = 10 ** math.floor(math.log10(min(v for _, v in data)))
        hi = vmax or max(v for _, v in data) * 1.6
        y = lambda v: ph * math.log10(v / lo) / math.log10(hi / lo)
    else:
        hi = vmax or max(v for _, v in data) * 1.15
        y = lambda v: ph * v / hi
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">', STYLE,
           f'<text class="t" x="{LEFT}" y="26">{title}</text>',
           f'<text class="s" x="{LEFT}" y="46">{sub}</text>']
    base = TOP + ph
    out.append(f'<line class="g" x1="{LEFT}" x2="{W - RIGHT}" y1="{base}" y2="{base}"/>')
    for i, (lang, v) in enumerate(data):
        cx = LEFT + slot * (i + 0.5)
        h = max(2, y(v))
        cls = "f" if lang.startswith("Fih") else "b"
        out.append(f'<rect class="{cls}" x="{cx - bw / 2:.1f}" y="{base - h:.1f}" width="{bw:.1f}" height="{h:.1f}" rx="3"/>')
        out.append(f'<text class="v" x="{cx:.1f}" y="{base - h - 6:.1f}" text-anchor="middle">{label(v)}</text>')
        out.append(f'<text class="l" x="{cx:.1f}" y="{base + 20}" text-anchor="middle">{lang}</text>')
    out.append("</svg>")
    open(f"docs/{name}.svg", "w").write("\n".join(out) + "\n")


rows = defaultdict(list)
for r in csv.DictReader(open("bench/results.csv")):
    rows[r["test"]].append((r["lang"], float(r["value"])))

logsub = "wyżej = lepiej · skala logarytmiczna"
chart("exec", "Wykonanie gotowego programu [linii/s]",
      f"100 000 linii print/calc; Fih (build), C, C++ już skompilowane · {logsub}", rows["exec"], True)
chart("source", "Od kodu źródłowego do wyniku [linii/s]",
      f"kompilacja (fih build / gcc -O2 / g++ -O2) + wykonanie · {logsub}", rows["source"], True)
chart("startup", "Hello World [uruchomień/s]", f"ile razy na sekundę da się uruchomić program · {logsub}",
      rows["startup"], True)
chart("exec1", "Wykonanie na jednym rdzeniu [linii/s]",
      "taskset -c 0: interpretowany Fih vs skompilowane C · wyżej = lepiej", rows["exec1"], False)

passed, total = defaultdict(int), defaultdict(int)
for r in csv.DictReader(open("bench/stability.csv")):
    passed[r["lang"]] += int(r["ok"])
    total[r["lang"]] += 1
cases = max(total.values())
chart("stability", f"Stabilność: zaliczone złośliwe przypadki [na {cases}]",
      "brak awarii, poprawny kod wyjścia, brak cichej utraty danych i złych wyników · wyżej = lepiej",
      list(passed.items()), False, label=lambda v: f"{v:.0f}/{cases}", vmax=cases * 1.12)
print("zapisano docs/*.svg")
