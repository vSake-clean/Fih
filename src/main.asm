; main.asm — punkt wejścia
;   fih program.fh                       interpretacja (od razu wykonuje)
;   fih build program.fh [-o wynik]      kompilacja do pliku wykonywalnego
;   fih --help | -h                      opis użycia (stdout, kod 0)
;   fih --version                        wersja (stdout, kod 0)
;
; Program jest najpierw wykonywany szybkim silnikiem 0.1 (interp.asm, tylko
; print i calc, na wielu rdzeniach) z wyjściem zbieranym w pamięci. Gdy ten
; trafi na cokolwiek innego (zmienne, if, while, błąd), wraca tu (bail_ip),
; a program kompiluje comp.asm: sprawdza cały plik, potem uruchamia kod
; maszynowy w pamięci (JIT) albo zapisuje go jako plik ELF.
%include "fih.inc"
default rel

global _start
extern run_program, out_to_memory, out_reset, out_held_stdout
extern write_all, write_elf, die_noline, expr_init, bail_rsp, bail_ip
extern comp_compile, comp_run_jit, comp_write_elf

%define PATH_MAX 4096

%define SA_RESTORER 0x04000000
%define SYS_RT_SIGRETURN 15

section .bss
statbuf:  resb 144          ; struct stat, st_size pod offsetem 48
out_path: resb PATH_MAX
src_ptr:  resq 1            ; wczytany program
src_len:  resq 1

section .rodata
msg_usage:      db "użycie:", 10
                db "  fih program.fh                    uruchamia program", 10
                db "  fih build program.fh [-o wynik]   kompiluje do pliku wykonywalnego", 10
                db "  fih --help                        ten opis", 10
                db "  fih --version                     wersja", 10
msg_usage_len   equ $ - msg_usage
msg_help:       db "Fih ", FIH_VERSION, " — język programowania w assembly x86-64", 10, 10
msg_help_usage_len equ $ - msg_help
                db 10, "Instrukcje (jedna na linię, komentarze od #):", 10
                db '  print("napis")      wypisuje napis; sekwencje \n \t \\ \"', 10
                db '  calc("wyrażenie")   liczy wyrażenie całkowite 64-bit: + - * / % ( )', 10, 10
                db "Kody wyjścia: 0 sukces, 1 błąd w programie, 2 złe argumenty.", 10
                db "Specyfikacja: https://github.com/vSake-clean/Fih/blob/main/SPEC.md", 10
msg_help_len    equ $ - msg_help
msg_version:    db "fih ", FIH_VERSION, 10
msg_version_len equ $ - msg_version
msg_open:       db "nie można otworzyć pliku"
msg_open_len    equ $ - msg_open
msg_read:       db "nie można wczytać pliku"
msg_read_len    equ $ - msg_read
msg_noext:      db "plik nie ma rozszerzenia .fh — podaj nazwę wyniku: -o nazwa"
msg_noext_len   equ $ - msg_noext
msg_same:       db "plik wynikowy nadpisałby plik źródłowy"
msg_same_len    equ $ - msg_same
msg_changed:    db "plik źródłowy zmienił się (skrócił) podczas wykonania"
msg_changed_len equ $ - msg_changed
msg_long:       db "za długa ścieżka"
msg_long_len    equ $ - msg_long
str_build:      db "build", 0
str_o:          db "-o", 0
str_help:       db "--help", 0
str_h:          db "-h", 0
str_version:    db "--version", 0

section .text
_start:
    call out_reset
    call expr_init
    ; plik jest mapowany (mmap); gdy ktoś go skróci w trakcie, odczyt daje
    ; SIGBUS — zamiast awarii zgłaszamy zwykły błąd
    ; struct sigaction jądra na stosie: handler, flagi, restorer, maska
    ; (x86-64 wymaga SA_RESTORER, choć nasz handler nigdy nie wraca)
    sub rsp, 32
    lea rax, [on_sigbus]
    mov [rsp], rax
    mov qword [rsp+8], SA_RESTORER
    lea rax, [sig_restorer]
    mov [rsp+16], rax
    mov qword [rsp+24], 0
    mov eax, SYS_RT_SIGACTION
    mov edi, SIGBUS
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    syscall
    add rsp, 32
    mov rbx, [rsp]          ; argc
    cmp rbx, 2
    jb .usage
    cmp rbx, 2
    jne .not_flag
    mov rdi, [rsp+16]
    lea rsi, [str_help]
    call streq
    je .help
    mov rdi, [rsp+16]
    lea rsi, [str_h]
    call streq
    je .help
    mov rdi, [rsp+16]
    lea rsi, [str_version]
    call streq
    je .version
.not_flag:
    mov rdi, [rsp+16]       ; argv[1]
    lea rsi, [str_build]
    call streq
    jne .interpret

    ; --- fih build plik.fh [-o wynik] ---
    mov r14, [rsp+24]       ; argv[2] = źródło
    cmp rbx, 3
    je .default_name
    cmp rbx, 5
    jne .usage
    mov rdi, [rsp+32]
    lea rsi, [str_o]
    call streq
    jne .usage
    mov r15, [rsp+40]       ; argv[4] = wynik
    jmp .have_name

.default_name:
    ; wynik = źródło bez końcówki ".fh"
    mov rdi, r14
    call strlen
    cmp rax, 3
    jbe .noext
    cmp byte [r14+rax-3], '.'
    jne .noext
    cmp word [r14+rax-2], 'fh'
    jne .noext
    sub rax, 3
    cmp rax, PATH_MAX - 1
    jae .toolong
    mov rcx, rax
    mov rsi, r14
    lea rdi, [out_path]
    rep movsb
    mov byte [rdi], 0
    lea r15, [out_path]

.have_name:
    mov rdi, r14
    mov rsi, r15
    call streq
    je .same

    mov rdi, r14
    call load_source
    call run_fast
    test eax, eax
    jnz .build_comp
    mov rdi, r15
    call write_elf
    jmp .exit_ok
.build_comp:
    mov rdi, [src_ptr]
    mov rsi, [src_len]
    call comp_compile
    mov rdi, r15
    call comp_write_elf
    jmp .exit_ok

    ; --- fih plik.fh ---
.interpret:
    cmp rbx, 2
    jne .usage
    mov rdi, [rsp+16]
    call load_source
    call run_fast
    test eax, eax
    jnz do_jit
    call out_held_stdout
.exit_ok:
    mov eax, SYS_EXIT
    xor edi, edi
    syscall

; opis użycia: nagłówek + linie "fih ..." z msg_usage + reszta msg_help
.help:
    mov edi, STDOUT
    lea rsi, [msg_help]
    mov edx, msg_help_usage_len
    call write_all
    mov edi, STDOUT
    lea rsi, [msg_usage]
    mov edx, msg_usage_len
    call write_all
    mov edi, STDOUT
    lea rsi, [msg_help + msg_help_usage_len]
    mov edx, msg_help_len - msg_help_usage_len
    call write_all
    jmp .exit_ok
.version:
    mov edi, STDOUT
    lea rsi, [msg_version]
    mov edx, msg_version_len
    call write_all
    jmp .exit_ok

.usage:
    mov edi, STDERR
    lea rsi, [msg_usage]
    mov edx, msg_usage_len
    call write_all
    mov eax, SYS_EXIT
    mov edi, 2
    syscall

.noext:
    lea rdi, [msg_noext]
    mov esi, msg_noext_len
    jmp die_noline
.same:
    lea rdi, [msg_same]
    mov esi, msg_same_len
    jmp die_noline
.toolong:
    lea rdi, [msg_long]
    mov esi, msg_long_len
    jmp die_noline

sig_restorer:
    mov eax, SYS_RT_SIGRETURN
    syscall

; on_sigbus — obsługa SIGBUS (nigdy nie wraca)
on_sigbus:
    lea rdi, [msg_changed]
    mov esi, msg_changed_len
    jmp die_noline

; programy 0.2: kompilacja i uruchomienie w pamięci
do_jit:
    mov rdi, [src_ptr]
    mov rsi, [src_len]
    call comp_compile
    jmp comp_run_jit

; run_fast -> eax = 0: program wykonał silnik 0.1, wynik w pamięci (io.asm);
; eax = 1: program wymaga kompilatora (wyjście porzucone)
run_fast:
    push rbx                ; powrót przez bail_ip omija epilogi funkcji —
    push rbp                ; rejestry zachowywane odtwarzamy sami
    push r12
    push r13
    push r14
    push r15
    mov rdi, [src_len]      ; wynik print/calc nie jest dłuższy niż program
    call out_to_memory
    mov [bail_rsp], rsp
    lea rax, [.bailed]
    mov [bail_ip], rax
    mov rsi, [src_len]
    test rsi, rsi
    jz .ok
    mov rdi, [src_ptr]
    call run_program
.ok:
    mov qword [bail_rsp], 0
    xor eax, eax
    jmp .ret
.bailed:
    call out_reset
    mov eax, 1
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; load_source(rdi=ścieżka) — wczytuje plik (mmap albo read) do src_ptr/src_len
load_source:
    push r12
    push r13
    push rbx
    mov eax, SYS_OPEN
    xor esi, esi            ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .open_fail
    mov r12, rax            ; fd

    mov eax, SYS_FSTAT
    mov rdi, r12
    lea rsi, [statbuf]
    syscall
    test rax, rax
    js .read_fail
    mov eax, [statbuf+24]   ; st_mode
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .stream             ; potok, /dev/stdin itp. — czytamy read()
    mov r13, [statbuf+48]   ; st_size
    test r13, r13
    jz .done                ; pusty plik — nic do zrobienia

    mov eax, SYS_MMAP
    xor edi, edi
    mov rsi, r13
    mov edx, PROT_READ
    mov r10d, MAP_PRIVATE   ; bez MAP_POPULATE: przy wielu rdzeniach każdy proces
    mov r8, r12             ; wczytuje tylko swój kawałek pliku
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae .read_fail

    mov [src_ptr], rax
    mov [src_len], r13
    jmp .done
.stream:
    mov edi, r12d
    call read_stream
    mov [src_ptr], rax
    mov [src_len], rdx
.done:
    mov eax, SYS_CLOSE
    mov rdi, r12
    syscall
    pop rbx
    pop r13
    pop r12
    ret

.open_fail:
    lea rdi, [msg_open]
    mov esi, msg_open_len
    jmp die_noline
.read_fail:
    lea rdi, [msg_read]
    mov esi, msg_read_len
    jmp die_noline

; read_stream(edi=fd) -> rax = bufor, rdx = długość
; czyta do końca strumienia do rosnącego bufora (mmap/mremap)
read_stream:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14d, edi
    xor ebx, ebx            ; bufor
    xor r12d, r12d          ; długość
    xor r13d, r13d          ; pojemność
.loop:
    cmp r12, r13
    jb .read
    lea r15, [r13*2]        ; nowa pojemność
    mov eax, 1 << 16
    cmp r15, rax
    cmovb r15, rax
    test rbx, rbx
    jz .fresh
    mov eax, SYS_MREMAP
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r15
    mov r10d, MREMAP_MAYMOVE
    syscall
    jmp .check
.fresh:
    mov eax, SYS_MMAP
    xor edi, edi
    mov rsi, r15
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    syscall
.check:
    cmp rax, -4095
    jae load_source.read_fail
    mov rbx, rax
    mov r13, r15
.read:
    mov eax, SYS_READ
    mov edi, r14d
    lea rsi, [rbx+r12]
    mov rdx, r13
    sub rdx, r12
    syscall
    cmp rax, -EINTR
    je .read
    test rax, rax
    js load_source.read_fail
    jz .eof
    add r12, rax
    jmp .loop
.eof:
    mov rax, rbx
    mov rdx, r12
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; streq(rdi, rsi) — ZF=1 gdy napisy zakończone zerem są równe
streq:
    mov al, [rdi]
    cmp al, [rsi]
    jne .done
    test al, al
    jz .done
    inc rdi
    inc rsi
    jmp streq
.done:
    ret

; strlen(rdi) -> rax
strlen:
    xor eax, eax
.loop:
    cmp byte [rdi+rax], 0
    je .done
    inc rax
    jmp .loop
.done:
    ret
