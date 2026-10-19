#!/usr/bin/env bash
# Plik źródłowy skrócony w trakcie wykonania: zamiast awarii (SIGBUS) ma być
# komunikat i kod 1, a build nie może zostawić pliku wynikowego.
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 bench/gen.py 1000000 "$T/g" >/dev/null
fail=0
for mode in run run1 build; do
    cp "$T/g/program.fh" "$T/p.fh"; rm -f "$T/bin"
    case $mode in
        run)   ./fih "$T/p.fh" >/dev/null 2>"$T/err" & ;;
        run1)  taskset -c 0 ./fih "$T/p.fh" >/dev/null 2>"$T/err" & ;;
        build) ./fih build "$T/p.fh" -o "$T/bin" >/dev/null 2>"$T/err" & ;;
    esac
    pid=$!; sleep 0.03; truncate -s 1000 "$T/p.fh"; wait $pid; code=$?
    msg=$(cat "$T/err")
    if [[ $code == 1 && "$msg" == "fih: błąd: plik źródłowy zmienił się (skrócił) podczas wykonania" && ! -e "$T/bin" ]]; then
        echo "ok   $mode"
    else
        echo "FAIL $mode (kod $code): $msg"; fail=1
    fi
done
exit $fail
