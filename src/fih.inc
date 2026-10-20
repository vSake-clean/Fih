; fih.inc — wspólne stałe i makra interpretera Fih

%define FIH_VERSION "0.3.1"

; obszar danych programów 0.2 (rejestr r15 w wygenerowanym kodzie i w rt.asm)
%define D_OUTLEN    0           ; zajęta część bufora wyjścia
%define D_INPOS     8           ; wejście: pozycja w buforze,
%define D_INLEN     16          ;   ilość danych w buforze,
%define D_INEND     24          ;   1 = read() zwrócił koniec,
%define D_INOK      32          ;   wynik inputok(),
%define D_EOF       40          ;   wynik eof(),
%define D_INSKIP    48          ;   1 = pomijamy resztę za długiej linii
%define D_BASEFD    56          ; folder programu dla importów: fd + 1 (0 = folder pliku wykonywalnego)
%define D_TMPPTR    64          ; obszar tymczasowy tekstów (wyniki pośrednie
%define D_TMPEND    72          ;   jednej instrukcji): wolne miejsce, koniec
%define D_TMPCHUNK  80          ;   kawałka, kawałek (dq poprzedni, dq rozmiar, dane)
%define D_HEAPPTR   88          ; pamięć zmiennych tekstowych: wolne miejsce,
%define D_HEAPEND   96          ;   koniec kawałka
%define D_RNG       104         ; stan generatora math.random (4 × dq, zera = bez ziarna)
%define D_OUTBUF    160         ; bufor wyjścia
%define D_OUTSZ     65536
%define D_INBUF     (D_OUTBUF + D_OUTSZ)    ; bufor wejścia
%define D_INSZ      65536
%define D_VARS      (D_INBUF + D_INSZ)      ; zmienne: 16 B każda (wartość, flaga "ma wartość")
%define SYS_MPROTECT 10
%define PROT_EXEC   4

%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_OPEN    2
%define SYS_FSTAT   5
%define SYS_CLOSE   3
%define SYS_MMAP    9
%define SYS_MREMAP  25
%define SYS_PIPE    22
%define SYS_FORK    57
%define SYS_WAIT4   61
%define SYS_KILL    62
%define SYS_UNLINK  87
%define SYS_SCHED_GETAFFINITY 204
%define SYS_EXIT_GROUP 231
%define SIGKILL     9
%define SIGBUS      7
%define SYS_RT_SIGACTION 13
%define SYS_PRCTL   157
%define PR_SET_PDEATHSIG 1
%define MAXP        8
%define SYS_FCHMOD  91
%define SYS_GETRLIMIT 97
%define SYS_EXIT    60
%define SYS_GETRANDOM 318

%define STDOUT      1
%define STDERR      2
%define EINTR       4
%define EIO         5
%define RLIMIT_STACK 3
%define S_IFMT      0o170000
%define S_IFREG     0o100000

%define PROT_READ   1
%define PROT_WRITE  2
%define MAP_PRIVATE 2
%define MAP_ANONYMOUS 0x20
%define MAP_POPULATE 0x8000
%define MAP_SHARED  1
%define MAP_NORESERVE 0x4000
%define SYS_MUNMAP  11
%define MREMAP_MAYMOVE 1

%define PATH_MAX    4096
%define SYS_OPENAT  257
%define AT_FDCWD    -100
%define O_PATH      0x200000
%define O_DIRECTORY 0x10000
%define O_CLOEXEC   0x80000

%define O_WRONLY    1
%define O_CREAT     64
%define O_TRUNC     512

; funkcje math w środowisku (rt_math.inc): rt_math1(edi = M1_*), rt_math2(edi = M2_*)
%define M1_SQRT     0
%define M1_SIN      1
%define M1_COS      2
%define M1_TAN      3
%define M1_ASIN     4
%define M1_ACOS     5
%define M1_ATAN     6
%define M1_EXP      7
%define M1_LOG      8
%define M1_LOG2     9
%define M1_LOG10    10
%define M1_FLOOR    11
%define M1_CEIL     12
%define M1_TRUNC    13
%define M1_ROUND    14
%define M1_ABS      15
%define M2_ATAN2    0
%define M2_HYPOT    1
%define M2_POW      2
%define M2_LOG      3
%define M2_ROUND    4
%define M2_MIN      5
%define M2_MAX      6
%define M2_RANDINT  7

; operatory dwuargumentowe (comp.asm; rt_darith i rt_numcmp w rt_flt.inc)
%define OP_OR   1
%define OP_AND  2
%define OP_EQ   3
%define OP_NE   4
%define OP_LT   5
%define OP_LE   6
%define OP_GT   7
%define OP_GE   8
%define OP_ADD  9
%define OP_SUB  10
%define OP_MUL  11
%define OP_IDIV 12              ; //: dzielenie całkowite
%define OP_MOD  13
%define OP_DIV  14              ; /: dzielenie z ułamkiem (import math)

; flagi opisu uprawnień (imp.asm -> rt_sandbox)
%define POL_FILES    1
%define POL_COMMANDS 2
%define POL_NET      4
%define POL_MATH     8
%define POL_BASE     16         ; są reguły z folderem względnym

; ERR etykieta, "komunikat" — skok pod etykietę kończy program błędem
; z numerem bieżącej linii (funkcja die z io.asm)
%macro ERR 2
%1:
    lea rdi, [%%msg]
    mov esi, %%len
    jmp die
[section .rodata]
%%msg: db %2
%%len equ $ - %%msg
__SECT__
%endmacro
