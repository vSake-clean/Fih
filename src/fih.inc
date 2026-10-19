; fih.inc — wspólne stałe i makra interpretera Fih

%define FIH_VERSION "0.1.1"

; obszar danych programów 0.2 (rejestr r15 w wygenerowanym kodzie i w rt.asm)
%define D_OUTLEN    0           ; zajęta część bufora wyjścia
%define D_OUTBUF    64          ; bufor wyjścia
%define D_OUTSZ     65536
%define D_VARS      (D_OUTBUF + D_OUTSZ)    ; zmienne: 16 B każda (wartość, flaga "ma wartość")
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

%define O_WRONLY    1
%define O_CREAT     64
%define O_TRUNC     512

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
