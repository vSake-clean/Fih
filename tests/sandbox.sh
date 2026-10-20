#!/usr/bin/env bash
# Blokady jądra z importów (rt_sandbox): program skompilowany przez fih jest
# zatrzymywany w gdb na wywołaniu exit (już po założeniu blokad), a exit jest
# podmieniany na inne wywołanie systemowe; sprawdzamy, co odpowiada jądro.
# Wymaga gdb; części z Landlock są pomijane, gdy jądro go nie ma.
cd "$(dirname "$0")/.."
command -v gdb >/dev/null || { echo "sandbox: brak gdb, pomijam"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

# wersja Landlock (0 = brak)
LL=$(python3 -c "
import ctypes
r = ctypes.CDLL(None, use_errno=True).syscall(444, None, 0, 1)
print(max(r, 0))")

# adres napisu "/proc/self/exe" z rt (obraz programu zaczyna się pod 0x4000bf)
off=$(nm build/rt.o | awk '/ rt_str_exe$/ {print $1}')
STR=$((0x4000bf + 0x$off))

# probe "importy" nr a1 a2 a3 -> wynik wywołania (rax)
probe() {
    printf '%b' "$1" > "$T/p.fh"
    printf 'x = 1\n' >> "$T/p.fh"
    ./fih build "$T/p.fh" -o "$T/p" || return
    gdb -q -batch -ex 'catch syscall exit' -ex run \
        -ex "set \$orig_rax=$2" -ex "set \$rdi=$3" -ex "set \$rsi=$4" -ex "set \$rdx=$5" \
        -ex stepi -ex 'p $rax' -ex kill "$T/p" 2>/dev/null | sed -n 's/^\$1 = //p'
}
# expect opis "importy" oczekiwany nr a1 a2 a3; oczekiwany: liczba, "ok" (>= 0)
expect() {
    local desc=$1 imp=$2 want=$3; shift 3
    local got; got=$(probe "$imp" "$@")
    if [[ $want == ok ]]; then [[ $got =~ ^[0-9]+$ ]] && ok || bad "$desc: $got"
    else [[ $got == "$want" ]] && ok || bad "$desc: $got (oczekiwano $want)"; fi
}
OPEN="257 -100 $STR 0"          # openat(AT_FDCWD, "/proc/self/exe", O_RDONLY)
SOCK="41 2 2 0"                 # socket(AF_INET, SOCK_DGRAM, 0)
FORK="57 0 0 0"
EXEC="59 $STR 0 0"              # execve("/proc/self/exe")
URING="425 1 0 0"               # io_uring_setup

# bez importów: żadnych nowych deskryptorów ani procesów, w każdym jądrze
expect "bez importów: plik"   ''                 -24 $OPEN
expect "bez importów: gniazdo" ''                -24 $SOCK
expect "bez importów: fork"   ''                 -11 $FORK
expect "net: gniazdo"         'import net\n'     ok  $SOCK
expect "net: fork"            'import net\n'     -11 $FORK
expect "commands: fork"       'import commands\n' ok $FORK
expect "files: gniazdo (seccomp)" 'import files\n' -13 $SOCK
expect "files: io_uring (seccomp)" 'import files\n' -13 $URING
expect "files: execve (seccomp)" 'import files\n' -13 $EXEC
expect "files: plik"          'import files\n'   ok  $OPEN

if (( LL > 0 )); then
    expect "net: plik (Landlock)"            'import net\n'               -13 $OPEN
    expect "net: execve (Landlock)"          'import net\n'               -13 $EXEC
    expect "files ./dane: plik poza folderem" 'import files ./dane\n'     -13 $OPEN
    expect "files only list: odczyt pliku"   'import files only list\n'  -13 $OPEN
    expect "files only read: odczyt pliku"   'import files only read\n'  ok  $OPEN
    expect "dwa importy files: suma praw"    'import files only list\nimport files only read\n' ok $OPEN
else
    echo "sandbox: jądro bez Landlock, pomijam część testów"
fi

echo "sandbox: zaliczone: $pass, niezaliczone: $fail"
[[ $fail == 0 ]]
