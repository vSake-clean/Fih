#!/usr/bin/env bash
# Plik źródłowy skrócony w trakcie wykonania: zamiast awarii (SIGBUS) ma być
# komunikat i kod 1, a build nie może zostawić pliku wynikowego.
# Moment skrócenia zależy od szybkości maszyny, więc każdy tryb próbuje kilku
# opóźnień: żadna próba nie może skończyć się sygnałem, a co najmniej jedna
# musi trafić w trakcie wykonania (komunikat o skróceniu).
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 bench/gen.py 1000000 "$T/g" >/dev/null
msg_trunc="fih: błąd: plik źródłowy zmienił się (skrócił) podczas wykonania"
fail=0
for mode in run run1 build; do
    hit=0; bad=""
    for delay in 0.03 0.02 0.01 0.005 0.002 0.001 0.05 0.1; do
        cp "$T/g/program.fh" "$T/p.fh"; rm -f "$T/bin"
        case $mode in
            run)   ./fih "$T/p.fh" >/dev/null 2>"$T/err" & ;;
            run1)  taskset -c 0 ./fih "$T/p.fh" >/dev/null 2>"$T/err" & ;;
            build) ./fih build "$T/p.fh" -o "$T/bin" >/dev/null 2>"$T/err" & ;;
        esac
        pid=$!; sleep $delay; truncate -s 1000 "$T/p.fh"; wait $pid; code=$?
        msg=$(cat "$T/err")
        if [[ $code == 1 && "$msg" == "$msg_trunc" ]]; then
            [[ -e "$T/bin" ]] && bad="build zostawił plik wynikowy" || hit=1
        elif [[ $code -gt 1 ]]; then
            bad="kod $code (opóźnienie $delay): $msg"
        fi
        [[ -n $bad || $hit == 1 ]] && break
    done
    if [[ -z $bad && $hit == 1 ]]; then
        echo "ok   $mode"
    else
        echo "FAIL $mode: ${bad:-żadna próba nie trafiła w trakcie wykonania}"; fail=1
    fi
done
exit $fail
