#!/usr/bin/env bash
# Testy Fih — każdy przypadek sprawdzany w obu trybach:
#   interpretacja:  ./fih X.fh
#   kompilacja:     ./fih build X.fh -o tmp && ./tmp
#   tests/ok/X.fh  + X.out — oczekiwane stdout, kod wyjścia 0
#   tests/err/X.fh + X.err — oczekiwane stderr, kod wyjścia 1 (build: brak pliku wynikowego)
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

for f in tests/ok/*.fh; do
    exp="${f%.fh}.out"
    out=$(./fih "$f" 2>&1; echo "kod=$?")
    [[ "$out" == "$(cat "$exp"; echo "kod=0")" ]] && ok || bad "interpretacja $f"
    rm -f "$T/bin"
    if ./fih build "$f" -o "$T/bin" 2>"$T/err"; then
        out=$("$T/bin" 2>&1; echo "kod=$?")
        [[ "$out" == "$(cat "$exp"; echo "kod=0")" ]] && ok || bad "kompilacja $f"
    else
        bad "kompilacja $f: $(cat "$T/err")"
    fi
done

for f in tests/err/*.fh; do
    exp=$(cat "${f%.fh}.err")
    out=$(./fih "$f" 2>&1 >/dev/null); code=$?
    [[ $code == 1 && "$out" == "$exp" ]] && ok || bad "interpretacja $f (kod $code): $out"
    rm -f "$T/bin"
    out=$(./fih build "$f" -o "$T/bin" 2>&1); code=$?
    [[ $code == 1 && "$out" == "$exp" && ! -e "$T/bin" ]] && ok || bad "kompilacja $f (kod $code): $out"
done

# wiersz poleceń
check() { # opis, oczekiwany kod, polecenie...
    local desc=$1 want=$2; shift 2
    "$@" >/dev/null 2>&1; local code=$?
    [[ $code == "$want" ]] && ok || bad "$desc (kod $code, oczekiwano $want)"
}
check "bez argumentów"          2 ./fih
check "build bez pliku"         2 ./fih build
check "za dużo argumentów"      2 ./fih a.fh b.fh
check "build zła flaga"         2 ./fih build tests/ok/calc.fh -x out
check "brak pliku"              1 ./fih "$T/nie_ma.fh"
check "katalog"                 1 ./fih tests
check "build bez .fh"           1 ./fih build README.md
check "build nadpisałby źródło" 1 ./fih build tests/ok/calc.fh -o tests/ok/calc.fh
check "build do złego katalogu" 1 ./fih build tests/ok/calc.fh -o "$T/brak/x"
check "--help"                  0 ./fih --help
check "-h"                      0 ./fih -h
check "--version"               0 ./fih --version
check "--version z argumentem"  2 ./fih --version x
check "--help na pełny dysk"    1 sh -c './fih --help > /dev/full'
[[ "$(./fih --version)" == "fih $(sed -n 's/^%define FIH_VERSION "\(.*\)"/\1/p' src/fih.inc)" ]] && ok || bad "--version: treść"
[[ "$(./fih --help | head -1)" == Fih* && -z "$(./fih --help 2>&1 >/dev/null)" ]] && ok || bad "--help: na stdout"
cp tests/ok/calc.fh "$T/prog.fh"
./fih build "$T/prog.fh" && [[ -x "$T/prog" ]] && ok || bad "build: domyślna nazwa wyniku"
echo 'stary' > "$T/prog" && chmod 600 "$T/prog" && ./fih build "$T/prog.fh" && [[ -x "$T/prog" && "$("$T/prog" | head -1)" == 4 ]] \
    && ok || bad "build: nadpisanie istniejącego pliku"
"$T/prog" > /dev/full 2>/dev/null; [[ $? == 1 ]] && ok || bad "skompilowany: błąd zapisu daje kod 1"
./fih tests/ok/calc.fh > /dev/full 2>/dev/null; [[ $? == 1 ]] && ok || bad "interpretacja: błąd zapisu daje kod 1"

# przypadki graniczne
python3 -c "print('calc(\"' + '('*2000000 + '1' + ')'*2000000 + '\")')" > "$T/deep.fh"
[[ "$(./fih "$T/deep.fh" 2>&1)" == "fih: błąd w linii 1: wyrażenie zbyt głęboko zagnieżdżone" ]] && ok || bad "głębokie nawiasy"
python3 -c "print('calc(\"' + '-'*3000000 + '1\")')" > "$T/deep2.fh"
[[ "$(./fih "$T/deep2.fh" 2>&1)" == 1 ]] && ok || bad "3 mln minusów (bez rekurencji)"
python3 -c "print('calc(\"' + '('*10000 + '7' + ')'*10000 + '\")')" > "$T/nest.fh"
[[ "$(./fih "$T/nest.fh")" == 7 ]] && ok || bad "10000 nawiasów"
python3 -c "print('print(\"' + 'ryba'*100000 + '\")'); print('calc(\"1\")'); print('print(\"' + 'x\\\\n'*50000 + '\")')" > "$T/big.fh"
python3 -c "print('ryba'*100000); print(1); print('x\\n'*50000)" > "$T/big.out"
cmp -s <(./fih "$T/big.fh") "$T/big.out" && ok || bad "napis większy niż bufor wyjścia"
./fih build "$T/big.fh" -o "$T/big" && cmp -s <("$T/big") "$T/big.out" && ok || bad "build: duży wynik"
: > "$T/empty.fh"; ./fih build "$T/empty.fh" && [[ -x "$T/empty" && -z "$("$T/empty")" ]] && ok || bad "build: pusty program"
# strumienie i ograniczenia systemu
[[ "$(echo 'calc("6*7")' | ./fih /dev/stdin)" == 42 ]] && ok || bad "program z potoku"
cmp -s <(cat "$T/big.fh" | ./fih /dev/stdin) "$T/big.out" && ok || bad "duży program z potoku"
python3 -c "print('calc(\"' + '('*20000 + '1' + ')'*20000 + '\")')" > "$T/d20k.fh"
[[ "$(ulimit -s 256; ./fih "$T/d20k.fh" 2>&1)" == "fih: błąd w linii 1: wyrażenie zbyt głęboko zagnieżdżone" ]] && ok || bad "mały stos (ulimit -s 256)"
[[ "$(ulimit -s unlimited; ./fih "$T/d20k.fh")" == 1 ]] && ok || bad "stos bez limitu"
[[ "$(./fih tests/ok/calc.fh 2>&1 >/dev/full)" == "fih: błąd: nie można zapisać wyjścia" ]] && ok || bad "komunikat błędu zapisu"
# tryb wielordzeniowy (programy > 512 KB) i jego ścieżki awaryjne
python3 bench/gen.py 30000 "$T/par" >/dev/null
python3 "$T/par/program.py" > "$T/par/expected"
cmp -s <(./fih "$T/par/program.fh") "$T/par/expected" && ok || bad "wielordzeniowo: wynik"
cmp -s <(taskset -c 0 ./fih "$T/par/program.fh") "$T/par/expected" && ok || bad "jeden rdzeń: wynik"
cmp -s <(prlimit --nproc=1 ./fih "$T/par/program.fh") "$T/par/expected" && ok || bad "fork niemożliwy: wynik"
cmp -s <(ulimit -v 200000; ./fih "$T/par/program.fh") "$T/par/expected" && ok || bad "mało pamięci wirtualnej: wynik"
./fih build "$T/par/program.fh" -o "$T/par/bin" && cmp -s <("$T/par/bin") "$T/par/expected" && ok || bad "wielordzeniowo: build"
{ cat "$T/par/program.fh"; echo 'calc("1/0")'; } > "$T/par/err.fh"
[[ "$(./fih "$T/par/err.fh" 2>&1 >/dev/null)" == "fih: błąd w linii 30001: dzielenie przez zero" ]] && ok || bad "wielordzeniowo: numer linii błędu"
cmp -s <(./fih "$T/par/err.fh" 2>/dev/null) "$T/par/expected" && ok || bad "wielordzeniowo: wyjście przed błędem"
[[ "$(prlimit --nproc=1 ./fih "$T/par/err.fh" 2>&1 >/dev/null)" == "fih: błąd w linii 30001: dzielenie przez zero" ]] && ok || bad "fork niemożliwy: numer linii błędu"
python3 tests/output_numbers.py ./fih && ok || bad "wypisywanie liczb (tests/output_numbers.py)"
python3 tests/division.py ./fih && ok || bad "dzielenie (tests/division.py)"
python3 tests/numbers.py ./fih && ok || bad "parsowanie liczb (tests/numbers.py)"
head -c 100000 /dev/urandom > "$T/rand.fh"; ./fih "$T/rand.fh" >/dev/null 2>&1; code=$?; [[ $code -le 1 ]] && ok || bad "losowe bajty"

echo "zaliczone: $pass, niezaliczone: $fail"
[[ $fail == 0 ]]
