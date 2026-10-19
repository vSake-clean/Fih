; par.asm — wykonanie dużego programu na wielu rdzeniach
;
; Linie programu są od siebie niezależne, więc dzielimy plik na N kawałków
; na granicach linii (N = liczba dostępnych rdzeni, max MAXP). Kawałek 0
; wykonuje rodzic, a każdy następny proces potomny (fork) wprost do pamięci
; dzielonej (MAP_SHARED): [długość wyniku: 8 B][wynik]. Rodzic czeka na
; potomków po kolei i wypisuje ich wyniki bez kopiowania.
; Gdy kawałek potomka zawiera błąd (albo fork się nie uda), rodzic wykonuje
; resztę programu sam, od początku tego kawałka — wyjście i komunikat błędu
; (z numerem linii) są więc dokładnie takie jak przy wykonaniu po kolei.
%include "fih.inc"
default rel

global run_program
extern run, out_flush, out_raw, out_to_fixed_memory, mem_len
extern quiet_errors, child_pids, kill_children

%define PAR_MIN (512 * 1024)    ; mniejsze programy: zwykłe wykonanie
%define SHM_SIZE (1 << 33)      ; 8 GB przestrzeni adresowej na potomka (bez rezerwacji)

section .bss
bounds:  resq MAXP + 1          ; początki kawałków; bounds[N] = koniec
shm:     resq MAXP              ; pamięć dzielona kawałka i
cpuset:  resb 128
status:  resq 1

section .text

; run_program(rdi=kod, rsi=długość) — wykonuje cały program
run_program:
    cmp rsi, PAR_MIN
    jae .big
    mov edx, 1
    jmp run
.big:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                ; R = początek
    mov r13, rsi                ; Z = długość
    call cpu_count
    cmp eax, 2
    jb .sequential
    mov ecx, MAXP
    cmp eax, ecx
    cmova eax, ecx
    mov ebx, eax                ; N

    ; granice kawałków: R + Z*i/N przesunięte za najbliższy '\n'
    mov [bounds], r12
    lea rax, [r12+r13]
    lea rcx, [bounds]
    mov [rcx + rbx*8], rax
    mov r14d, 1
.split:
    cmp r14d, ebx
    jae .forks
    mov rax, r13
    mul r14
    div rbx
    add rax, r12
    lea rcx, [bounds]
    mov rdx, [rcx + r14*8 - 8]
    cmp rax, rdx
    cmovb rax, rdx
    lea rdx, [r12+r13]
.scan:
    cmp rax, rdx
    jae .cut
    cmp byte [rax], 10
    je .newline
    inc rax
    jmp .scan
.newline:
    inc rax
.cut:
    mov [rcx + r14*8], rax
    inc r14d
    jmp .split

    ; procesy potomne dla kawałków 1..N-1
.forks:
    mov r14d, 1
.fork:
    cmp r14d, ebx
    jae .parent
    mov eax, SYS_MMAP
    xor edi, edi
    mov rsi, SHM_SIZE
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_SHARED | MAP_ANONYMOUS | MAP_NORESERVE
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae .fork_next              ; brak pamięci — kawałek wykona rodzic
    lea rcx, [shm]
    mov [rcx + r14*8], rax
    mov eax, SYS_FORK
    syscall
    test rax, rax
    jz .child
    js .fork_next
    lea rcx, [child_pids]
    mov [rcx + r14*8], rax
.fork_next:
    inc r14d
    jmp .fork

    ; rodzic: kawałek 0, potem wyniki potomków po kolei
.parent:
    mov rdi, r12
    mov rsi, [bounds + 8]
    sub rsi, r12
    mov edx, 1
    call run
    mov r14d, 1
.collect:
    cmp r14d, ebx
    jae .done
    lea rcx, [child_pids]
    mov r15, [rcx + r14*8]
    test r15, r15
    jz .inline                  ; ten kawałek nie ma procesu
.wait:
    mov eax, SYS_WAIT4
    mov rdi, r15
    lea rsi, [status]
    xor edx, edx
    xor r10d, r10d
    syscall
    cmp rax, -EINTR
    je .wait
    lea rcx, [child_pids]
    mov qword [rcx + r14*8], 0
    test rax, rax
    js .fallback
    cmp dword [status], 0       ; zakończony normalnie z kodem 0
    jne .fallback
    call out_flush
    lea rcx, [shm]
    mov rbp, [rcx + r14*8]
    lea rsi, [rbp + 8]
    mov rdx, [rbp]
    call out_raw
    mov eax, SYS_MUNMAP
    mov rdi, rbp
    mov rsi, SHM_SIZE
    syscall
    inc r14d
    jmp .collect

.inline:
    lea rcx, [bounds]
    mov rsi, [rcx + r14*8]
    mov rdi, r12
    call line_of
    mov rdx, rax
    lea rcx, [bounds]
    mov rdi, [rcx + r14*8]
    mov rsi, [rcx + r14*8 + 8]
    sub rsi, rdi
    call run
    inc r14d
    jmp .collect

    ; błąd w kawałku potomka: reszta programu po kolei w rodzicu
.fallback:
    call kill_children
    lea rcx, [bounds]
    mov rsi, [rcx + r14*8]
    mov rdi, r12
    call line_of
    mov rdx, rax
    lea rcx, [bounds]
    mov rdi, [rcx + r14*8]
    lea rsi, [r12+r13]
    sub rsi, rdi
    call run
    jmp .done

.sequential:
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    call run
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

    ; proces potomny: kawałek r14 do pamięci, wynik do rury
.child:
    ; gdy rodzic zginie (np. SIGPIPE przy "| head"), potomek ginie razem z nim
    mov eax, SYS_PRCTL
    mov edi, PR_SET_PDEATHSIG
    mov esi, SIGKILL
    syscall
    mov qword [quiet_errors], 1
    lea rdi, [child_pids]
    xor eax, eax
    mov ecx, MAXP
    rep stosq
    lea rcx, [shm]
    mov rbp, [rcx + r14*8]
    lea rdi, [rbp + 8]
    mov rsi, SHM_SIZE - 8
    call out_to_fixed_memory
    lea rcx, [bounds]
    mov rdi, [rcx + r14*8]
    mov rsi, [rcx + r14*8 + 8]
    sub rsi, rdi
    mov edx, 1
    call run
    call out_flush
    mov rax, [mem_len]
    mov [rbp], rax
    mov eax, SYS_EXIT_GROUP
    xor edi, edi
    syscall

; line_of(rdi=początek programu, rsi=pozycja) -> rax = numer linii pozycji
line_of:
    mov eax, 1
.loop:
    cmp rdi, rsi
    jae .done
    cmp byte [rdi], 10
    jne .next
    inc rax
.next:
    inc rdi
    jmp .loop
.done:
    ret

; cpu_count() -> eax = liczba rdzeni, na których proces może działać
cpu_count:
    mov eax, SYS_SCHED_GETAFFINITY
    xor edi, edi
    mov esi, 128
    lea rdx, [cpuset]
    syscall
    test rax, rax
    jle .one
    mov rcx, rax
    xor eax, eax
    lea rsi, [cpuset]
.byte:
    movzx edx, byte [rsi]
.bit:
    test edx, edx
    jz .next_byte
    mov r8d, edx
    and r8d, 1
    add eax, r8d
    shr edx, 1
    jmp .bit
.next_byte:
    inc rsi
    dec rcx
    jnz .byte
    ret
.one:
    mov eax, 1
    ret
