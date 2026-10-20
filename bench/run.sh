#!/usr/bin/env bash
# Benchmark Fih vs C, C++, Python. Wynik: bench/results.json + wykres w terminalu.
set -euo pipefail
cd "$(dirname "$0")/.."
N=${N:-100000}
O=bench/out
PY=/usr/bin/python3

python3 bench/gen.py "$N" "$O"
echo "kompilacja Fih (fih build) i C/C++ (gcc -O2)..."
./fih build $O/program.fh -o $O/prog_fih
./fih build $O/hello/hello.fh -o $O/hello/hello_fih
gcc -O2 -o $O/prog_c   $O/program.c
g++ -O2 -o $O/prog_cpp $O/program.cpp
gcc -O2 -o $O/hello/hello_c   $O/hello/hello.c
g++ -O2 -o $O/hello/hello_cpp $O/hello/hello.cpp

echo "sprawdzanie, czy wszystkie wersje dają ten sam wynik..."
./fih $O/program.fh > $O/expected.txt
for cmd in "$O/prog_fih" "$PY $O/program.py" "$O/prog_c" "$O/prog_cpp"; do
    $cmd | cmp -s - $O/expected.txt || { echo "RÓŻNY WYNIK: $cmd"; exit 1; }
done
echo "  OK — identyczne wyjście ($(wc -l < $O/expected.txt) linii)"

hf() { hyperfine -N --style basic "$@"; }

hf --warmup 3 --export-json $O/exec.json \
   -n Fih "./fih $O/program.fh" -n "Fih (build)" "$O/prog_fih" -n Python "$PY $O/program.py" \
   -n C "$O/prog_c" -n C++ "$O/prog_cpp"

# to samo przypięte do jednego rdzenia (Fih domyślnie używa wszystkich)
hf --warmup 3 --export-json $O/exec1.json \
   -n Fih "taskset -c 0 ./fih $O/program.fh" -n C "taskset -c 0 $O/prog_c"

hf --warmup 3 --export-json $O/compile_fih.json \
   -n "Fih (build)" "./fih build $O/program.fh -o $O/tmp_fih"

# kompilacja C/C++ trwa ~10 min na wolnym CPU — wynik jest zapamiętywany;
# FULL=1 wymusza ponowny pomiar
if [[ ${FULL:-0} == 1 || ! -f $O/compile.json ]]; then
    hf --warmup 1 --runs 3 --export-json $O/compile.json \
       -n C "gcc -O2 -o $O/tmp_c $O/program.c" -n C++ "g++ -O2 -o $O/tmp_cpp $O/program.cpp"
else
    echo "(kompilacja C/C++: wynik z poprzedniego pomiaru, FULL=1 mierzy od nowa)"
fi

hf --warmup 10 --export-json $O/hello.json \
   -n Fih "./fih $O/hello/hello.fh" -n "Fih (build)" "$O/hello/hello_fih" -n Python "$PY $O/hello/hello.py" \
   -n C "$O/hello/hello_c" -n C++ "$O/hello/hello_cpp"

# pętle (Fih 0.2): liczby pierwsze dzieleniem próbnym, ten sam algorytm wszędzie
P=bench/primes
echo "benchmark pętli (liczby pierwsze)..."
./fih build $P/primes.fh -o $O/primes_fih
gcc -O2 -o $O/primes_c $P/primes.c
g++ -O2 -o $O/primes_cpp $P/primes.cpp
exp=$(./fih $P/primes.fh)
for cmd in "$O/primes_fih" "$PY $P/primes.py" "$O/primes_c" "$O/primes_cpp"; do
    [[ "$($cmd)" == "$exp" ]] || { echo "RÓŻNY WYNIK: $cmd"; exit 1; }
done
hf --warmup 2 --export-json $O/loops.json \
   -n Fih "./fih $P/primes.fh" -n "Fih (build)" "$O/primes_fih" -n Python "$PY $P/primes.py" \
   -n C "$O/primes_c" -n C++ "$O/primes_cpp"

# ułamki (0.4, import math): zbiór Mandelbrota i suma math.sqrt
F=bench/floats
for b in mandel sqrt; do
    echo "benchmark ułamków ($b)..."
    ./fih build $F/$b.fh -o $O/${b}_fih
    gcc -O2 -o $O/${b}_c $F/$b.c -lm
    g++ -O2 -o $O/${b}_cpp $F/$b.cpp
    exp=$(./fih $F/$b.fh)
    for cmd in "$O/${b}_fih" "$PY $F/$b.py" "$O/${b}_c" "$O/${b}_cpp"; do
        [[ "$($cmd)" == "$exp" ]] || { echo "RÓŻNY WYNIK: $cmd"; exit 1; }
    done
    hf --warmup 2 --export-json $O/$b.json \
       -n Fih "./fih $F/$b.fh" -n "Fih (build)" "$O/${b}_fih" -n Python "$PY $F/$b.py" \
       -n C "$O/${b}_c" -n C++ "$O/${b}_cpp"
done

python3 bench/report.py "$N" "$O"
