#!/usr/bin/env python3
"""Fuzzer bez wyroczni: losowe bajty i mutacje bajtowe poprawnych programów.
Fih ma zawsze zakończyć się kodem 0 lub 1 (nigdy sygnałem, nigdy zawieszeniem),
w interpretacji i kompilacji, także przy ulimit -s 256.

użycie: crash_fuzz.py [liczba] [ziarno]"""
import os, random, resource, subprocess, sys, tempfile
FIH = os.environ.get("FIH") or os.path.join(os.path.dirname(__file__), "..", "..", "fih")
n = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
seed = int(sys.argv[2]) if len(sys.argv) > 2 else random.randrange(1 << 30)
r = random.Random(seed)
seeds = [b'print("ryba")\ncalc("(1 + 2) * -3 // 4 % 5")\n', b'calc("9223372036854775807+1")\n# k\n',
         b'print("a\\tb\\\\c\\"d\\n")\n', b'calc("' + b"(" * 50 + b"1" + b")" * 50 + b'")\n']
tmp = tempfile.mkdtemp(); p = os.path.join(tmp, "p.fh"); out = os.path.join(tmp, "o")
small = lambda: resource.setrlimit(resource.RLIMIT_STACK, (256 * 1024, 256 * 1024))
bad = 0
for i in range(n):
    k = r.random()
    if k < 0.3:
        data = bytes(r.randrange(256) for _ in range(r.randint(0, 300)))
    else:
        data = bytearray(r.choice(seeds) * r.randint(1, 4))
        for _ in range(r.randint(1, 8)):
            j = r.randrange(len(data) + 1); op = r.random()
            if op < 0.4: data[j:j] = bytes([r.randrange(256)])
            elif op < 0.7 and j < len(data): del data[j]
            elif j < len(data): data[j] = r.randrange(256)
        data = bytes(data)
    open(p, "wb").write(data)
    for args, pre in (([FIH, p], None), ([FIH, "build", p, "-o", out], None), ([FIH, p], small)):
        res = subprocess.run(args, capture_output=True, timeout=10, preexec_fn=pre)
        if res.returncode not in (0, 1):
            bad += 1
            open(os.path.join(os.path.dirname(__file__), f"crash_{seed}_{i}.fh"), "wb").write(data)
            print(f"AWARIA #{i}: {args[1:]} kod {res.returncode}")
print(f"ziarno {seed}: {n} plików × 3 uruchomienia, awarii: {bad}")
sys.exit(1 if bad else 0)
