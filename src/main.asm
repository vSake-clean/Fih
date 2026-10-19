; main.asm — punkt wejścia
;   fih program.fh                       interpretacja (od razu wykonuje)
;   fih build program.fh [-o wynik]      kompilacja do pliku wykonywalnego
%include "fih.inc"
default rel

global _start
extern run_program, out_flush, out_to_memory, mem_ptr, mem_len
extern write_all, write_elf, die_noline, expr_init

%define PATH_MAX 4096

%define SA_RESTORER 0x04000000
%define SYS_RT_SIGRETURN 15

section .bss
statbuf:  resb 144          ; struct stat, st_size pod offsetem 48
out_path: resb PATH_MAX

section .rodata
msg_usage:      db "użycie:", 10
                db "  fih program.fh                    uruchamia program", 10
                db "  fih build program.fh [-o wynik]   kompiluje do pliku wykonywalnego", 10
msg_usage_len   equ $ - msg_usage
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

section .text
_start:
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

    call out_to_memory
    mov rdi, r14
    call load_and_run
    call out_flush
    mov rdi, r15
    mov rsi, [mem_ptr]
    mov rdx, [mem_len]
    call write_elf
    jmp .exit_ok

    ; --- fih plik.fh ---
.interpret:
    cmp rbx, 2
    jne .usage
    mov rdi, [rsp+16]
    call load_and_run
    call out_flush
.exit_ok:
    mov eax, SYS_EXIT
    xor edi, edi
    syscall

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

; load_and_run(rdi=ścieżka) — wczytuje plik (mmap) i wykonuje program
load_and_run:
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

    mov rdi, rax
    mov rsi, r13
    call run_program
    jmp .done
.stream:
    mov edi, r12d
    call read_stream
    test rdx, rdx
    jz .done
    mov rdi, rax
    mov rsi, rdx
    call run_program
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
    jae load_and_run.read_fail
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
    js load_and_run.read_fail
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
