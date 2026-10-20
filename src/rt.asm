; rt.asm — środowisko uruchomieniowe programów skompilowanych przez comp.asm
;
; Ten fragment kodu jest kopiowany bajt po bajcie na początek obrazu programu:
; do pamięci (JIT, tryb interpretacji) albo do pliku ELF (fih build). Dlatego:
;   - odwołuje się do siebie tylko względem RIP (działa pod każdym adresem),
;   - dane zmienne trzyma w obszarze danych wskazywanym przez r15
;     (bufor wyjścia, zmienne programu — patrz D_* w fih.inc),
;   - zaraz za rt_end w obrazie leży nagłówek: dq przesunięcie tabeli nazw
;     zmiennych od rt_begin (tabela: dd przesunięcie nazwy, dd długość).
;
; Wygenerowany kod woła te funkcje instrukcją call; żadna z nich nie zachowuje
; rejestrów poza r15 i rsp (wygenerowany kod nie trzyma wartości w rejestrach
; między instrukcjami programu).
%include "fih.inc"
default rel

global rt_begin, rt_end, rt_table

section .rt progbits alloc exec nowrite align=16

rt_begin:

; rt_write(rsi=dane, rdx=długość) — dopisuje do bufora wyjścia
rt_write:
    mov rax, [r15 + D_OUTLEN]
    lea rcx, [rax + rdx]
    cmp rcx, D_OUTSZ
    ja .slow
    mov [r15 + D_OUTLEN], rcx
    lea rdi, [r15 + D_OUTBUF + rax]
    cmp rdx, 16
    ja .long
    ; krótkie napisy: dwa nakładające się odczyty zamiast rep movsb
    cmp edx, 8
    jae .x8
    cmp edx, 4
    jae .x4
    test edx, edx
    jz .done
    movzx eax, byte [rsi]
    movzx ecx, byte [rsi + rdx - 1]
    mov [rdi], al
    mov [rdi + rdx - 1], cl
    cmp edx, 3
    jb .done
    movzx eax, byte [rsi + 1]
    mov [rdi + 1], al
.done:
    ret
.x4:
    mov eax, [rsi]
    mov ecx, [rsi + rdx - 4]
    mov [rdi], eax
    mov [rdi + rdx - 4], ecx
    ret
.x8:
    mov rax, [rsi]
    mov rcx, [rsi + rdx - 8]
    mov [rdi], rax
    mov [rdi + rdx - 8], rcx
    ret
.long:
    mov rcx, rdx
    rep movsb
    ret
.slow:
    push rsi
    push rdx
    call rt_flush
    pop rdx
    pop rsi
    cmp rdx, D_OUTSZ
    jb rt_write
    mov edi, STDOUT         ; za duże na bufor — od razu na wyjście
    jmp rt_write_or_die

; rt_int(rax=liczba ze znakiem) — wypisuje liczbę (bez '\n')
rt_int:
    sub rsp, 40
    lea rsi, [rsp + 33]
    mov r9d, 33
    jmp rt_int_digits

; rt_int_nl(rax=liczba ze znakiem) — wypisuje liczbę i '\n'
rt_int_nl:
    sub rsp, 40
    lea rsi, [rsp + 32]
    mov byte [rsi], 10
    mov r9d, 33
rt_int_digits:                      ; r9 = koniec zapisu względem rsp
    mov rcx, rax
    test rax, rax
    jns .digit
    neg rax                 ; INT64_MIN bez znaku daje poprawny moduł
.digit:
    xor edx, edx
    mov r8d, 10
    div r8
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .digit
    test rcx, rcx
    jns .write
    dec rsi
    mov byte [rsi], '-'
.write:
    lea rdx, [rsp + r9]
    sub rdx, rsi
    call rt_write
    add rsp, 40
    ret

; rt_readline -> rax = 0: linia (rsi = początek, rdx = długość bez '\n',
; albo rdx = -1, gdy linia ma 64 KB lub więcej); rax = 1: koniec wejścia.
; Najpierw opróżnia wyjście, żeby pytanie było widoczne przed wpisem.
rt_readline:
    call rt_flush
.scan:
    mov rsi, [r15 + D_INPOS]
    mov rcx, [r15 + D_INLEN]
    lea rdi, [r15 + D_INBUF]
    mov rdx, rsi
.find:
    cmp rdx, rcx
    jae .none
    cmp byte [rdi + rdx], 10
    je .found
    inc rdx
    jmp .find
.found:
    lea rax, [rdx + 1]
    mov [r15 + D_INPOS], rax
    cmp qword [r15 + D_INSKIP], 0
    jne .skipped
    sub rdx, rsi                    ; długość
    add rsi, rdi
    xor eax, eax
    ret
.skipped:                           ; koniec za długiej linii
    mov qword [r15 + D_INSKIP], 0
    mov rdx, -1
    xor eax, eax
    ret
.none:
    cmp qword [r15 + D_INEND], 0
    je .more
    ; koniec danych: ostatnia linia bez '\n' albo koniec wejścia
    mov [r15 + D_INPOS], rcx
    cmp qword [r15 + D_INSKIP], 0
    jne .skipped
    cmp rsi, rcx
    je .eof
    mov rdx, rcx
    sub rdx, rsi
    add rsi, rdi
    xor eax, eax
    ret
.eof:
    mov eax, 1
    ret
.more:
    ; przesuwamy niezużyte dane na początek bufora
    sub rcx, rsi
    push rcx
    lea rdi, [r15 + D_INBUF]
    lea rsi, [rdi + rsi]
    rep movsb
    pop rcx
    mov qword [r15 + D_INPOS], 0
    cmp rcx, D_INSZ
    jb .read
    mov qword [r15 + D_INSKIP], 1   ; 64 KB bez '\n': za długa linia, pomijamy
    xor ecx, ecx
.read:
    mov [r15 + D_INLEN], rcx
    mov eax, SYS_READ
    xor edi, edi
    lea rsi, [r15 + D_INBUF + rcx]
    mov edx, D_INSZ
    sub rdx, rcx
    syscall
    cmp rax, -EINTR
    je .read_again
    test rax, rax
    jg .got
    mov qword [r15 + D_INEND], 1    ; koniec albo błąd odczytu
    jmp .scan
.read_again:
    mov rcx, [r15 + D_INLEN]
    jmp .read
.got:
    add [r15 + D_INLEN], rax
    jmp .scan

; rt_input -> rax = liczba z linii wejścia (0, gdy to nie liczba);
; inputok() = 1 tylko dla poprawnej liczby, eof() = 1 po końcu wejścia
rt_input:
    call rt_readline
    test eax, eax
    jnz rt_in_eof
    mov qword [r15 + D_INOK], 0
    cmp rdx, -1
    je .bad
    call rt_trim
    test rdx, rdx
    jz .bad
    ; [+-]cyfry; liczymy ujemnie, żeby zmieścić -9223372036854775808
    xor r8d, r8d                    ; 1 = minus
    mov al, [rsi]
    cmp al, '+'
    je .sign
    cmp al, '-'
    jne .digits
    mov r8d, 1
.sign:
    inc rsi
    dec rdx
    jz .bad
.digits:
    xor eax, eax
.digit:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .bad
    imul rax, rax, 10
    jo .bad
    sub rax, rcx
    jo .bad
    inc rsi
    dec rdx
    jnz .digit
    test r8d, r8d
    jnz .ok
    neg rax
    jo .bad
.ok:
    mov qword [r15 + D_INOK], 1
    ret
.bad:
    xor eax, eax
    ret

rt_in_eof:
    mov qword [r15 + D_EOF], 1
    mov qword [r15 + D_INOK], 0
    xor eax, eax
    ret

; rt_inputchar -> rax = kod pierwszego znaku linii (bez spacji); 0 dla
; pustej linii, -1 po końcu wejścia
rt_inputchar:
    call rt_readline
    test eax, eax
    jz .line
    call rt_in_eof
    mov rax, -1
    ret
.line:
    mov qword [r15 + D_INOK], 0
    cmp rdx, -1
    je .empty
    call rt_trim
    test rdx, rdx
    jz .empty
    movzx eax, byte [rsi]
    mov qword [r15 + D_INOK], 1
    ret
.empty:
    xor eax, eax
    ret

; rt_trim(rsi, rdx) — obcina spacje, tabulatory i '\r' z obu stron
rt_trim:
.left:
    test rdx, rdx
    jz .done
    mov al, [rsi]
    cmp al, ' '
    je .l
    cmp al, 9
    je .l
    cmp al, 13
    jne .right
.l:
    inc rsi
    dec rdx
    jmp .left
.right:
    mov al, [rsi + rdx - 1]
    cmp al, ' '
    je .r
    cmp al, 9
    je .r
    cmp al, 13
    jne .done
.r:
    dec rdx
    jnz .right
.done:
    ret

; rt_flush() — opróżnia bufor wyjścia
rt_flush:
    mov rdx, [r15 + D_OUTLEN]
    mov qword [r15 + D_OUTLEN], 0
    lea rsi, [r15 + D_OUTBUF]
    mov edi, STDOUT
    ; dalej rt_write_or_die

; rt_write_or_die(edi=fd, rsi, rdx) — pisze całość; przy błędzie komunikat i kod 1
rt_write_or_die:
    call rt_write_fd
    test rax, rax
    jnz .fail
    ret
.fail:
    cmp edi, STDERR
    je rt_exit1             ; stderr też nie działa — tylko kod wyjścia
    mov edi, STDERR
    lea rsi, [rt_msg_wfail]
    mov edx, rt_msg_wfail_len
    call rt_write_fd
rt_exit1:
    mov eax, SYS_EXIT
    mov edi, 1
    syscall

; rt_write_fd(edi=fd, rsi, rdx) -> rax = 0 albo -errno (ponawia przy EINTR
; i krótkim zapisie; zapis 0 bajtów to błąd)
rt_write_fd:
    test rdx, rdx
    jz .ok
    mov eax, SYS_WRITE
    syscall
    cmp rax, -EINTR
    je rt_write_fd
    test rax, rax
    jle .err
    add rsi, rax
    sub rdx, rax
    jmp rt_write_fd
.ok:
    xor eax, eax
    ret
.err:
    jnz .ret
    mov rax, -EIO
.ret:
    ret

; rt_exit() — koniec programu: opróżnia wyjście, kod 0
rt_exit:
    call rt_flush
    mov eax, SYS_EXIT
    xor edi, edi
    syscall

; rt_die(edi=linia, esi=rodzaj: 0 przepełnienie, 1 dzielenie przez zero)
rt_die:
    push rdi
    push rsi
    call rt_flush
    call rt_err_prefix
    pop rsi
    lea rax, [rt_msg_ovf]
    mov edx, rt_msg_ovf_len
    lea rcx, [rt_msg_div0]
    mov r8d, rt_msg_div0_len
    test esi, esi
    cmovnz rax, rcx
    cmovnz edx, r8d
    mov rsi, rax
    mov edi, STDERR
    call rt_write_or_die
    jmp rt_err_end

; rt_die_var(edi=linia, esi=numer zmiennej) — "zmienna 'x' nie ma jeszcze wartości"
rt_die_var:
    push rdi
    push rsi
    call rt_flush
    call rt_err_prefix
    mov edi, STDERR
    lea rsi, [rt_msg_var1]
    mov edx, rt_msg_var1_len
    call rt_write_or_die
    pop rsi
    lea rcx, [rt_begin]
    mov rax, [rt_end]       ; nagłówek obrazu: przesunięcie tabeli nazw
    add rax, rcx
    mov edx, [rax + rsi*8 + 4]
    mov esi, [rax + rsi*8]
    add rsi, rcx
    mov edi, STDERR
    call rt_write_or_die
    mov edi, STDERR
    lea rsi, [rt_msg_var2]
    mov edx, rt_msg_var2_len
    call rt_write_or_die
    jmp rt_err_end

; rt_err_prefix — "fih: błąd w linii N: " na stderr (linia w [rsp+16])
rt_err_prefix:
    mov edi, STDERR
    lea rsi, [rt_msg_prefix]
    mov edx, rt_msg_prefix_len
    call rt_write_or_die
    mov eax, [rsp + 16]     ; numer linii (push rdi wywołującego)
    sub rsp, 32
    lea rsi, [rsp + 24]
    mov byte [rsi], ':'
    mov byte [rsi + 1], ' '
.digit:
    xor edx, edx
    mov ecx, 10
    div ecx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test eax, eax
    jnz .digit
    lea rdx, [rsp + 26]
    sub rdx, rsi
    mov edi, STDERR
    call rt_write_or_die
    add rsp, 32
    ret

rt_err_end:
    mov edi, STDERR
    lea rsi, [rt_msg_nl]
    mov edx, 1
    call rt_write_or_die
    jmp rt_exit1

; rt_sandbox — blokady jądra według importów (opis uprawnień: drugie pole
; nagłówka obrazu, format w imp.asm). Wołane na początku programu.
;   Landlock: pliki tylko według reguł import files, bez net — bez TCP,
;     bez sygnałów i gniazd abstrakcyjnych poza programem (ABI 6).
;     Bez commands nie ma prawa uruchamiania plików.
;   Limity zasobów: bez commands — bez nowych procesów, bez żadnego importu
;     — bez nowych deskryptorów (więc też bez gniazd i io_uring).
;   seccomp (kosztuje ~0,1 ms, więc tylko gdy potrzebny: files/commands bez
;     net albo jądro bez Landlock): bez net — bez gniazd, bez commands — bez
;     uruchamiania programów i nowych procesów; zawsze bez io_uring i ptrace.
%define SYS_LL_CREATE   444
%define SYS_LL_ADD      445
%define SYS_LL_RESTRICT 446
%define SYS_SECCOMP     317
%define SYS_READLINKAT  267
%define PR_SET_NO_NEW_PRIVS 38
%define SYS_SETRLIMIT   160
%define RLIMIT_NPROC    6
%define RLIMIT_NOFILE   7
%define EINVAL          22
%define LL_FILE_RIGHTS  0xc007      ; prawa dozwolone dla reguły na pliku (nie folderze)
; stos: [0] atrybuty zbioru reguł (24 B), [32] reguła ścieżki (12 B),
; [48] folder programu, [56] struct sock_fprog, [72] filtr seccomp
%define SB_FRAME 208
rt_sandbox:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    sub rsp, SB_FRAME
    lea rbx, [rt_begin]
    add rbx, [rt_end + 8]
    mov r12d, [rbx]                 ; flagi POL_*
    mov eax, SYS_LL_CREATE          ; wersja Landlock
    xor edi, edi
    xor esi, esi
    mov edx, 1                      ; LANDLOCK_CREATE_RULESET_VERSION
    syscall
    test rax, rax
    jle .ll_fail
    mov r13, rax
    mov r14d, 0x1fff                ; prawa obsługiwane przez tę wersję
    cmp r13, 2
    jb .attr0
    or r14d, 0x2000                 ; REFER
    cmp r13, 3
    jb .attr0
    or r14d, 0x4000                 ; TRUNCATE
    cmp r13, 5
    jb .attr0
    or r14d, 0x8000                 ; IOCTL_DEV
.attr0:
    mov [rsp], r14
    xor eax, eax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov esi, 8
    cmp r13, 4
    jb .attr
    mov esi, 16
    test r12d, POL_NET
    jnz .net
    mov qword [rsp + 8], 3          ; TCP: bind i connect
.net:
    cmp r13, 6
    jb .attr
    mov esi, 24
    mov qword [rsp + 16], 3         ; gniazda abstrakcyjne i sygnały
.attr:
    mov eax, SYS_LL_CREATE
    mov rdi, rsp
    xor edx, edx
    syscall
    test rax, rax
    js .ll_fail
    mov rbp, rax                    ; zbiór reguł
    mov qword [rsp + 48], -1
    test r12d, POL_BASE
    jz .rules
    mov rax, [r15 + D_BASEFD]       ; JIT: folder pliku .fh
    test rax, rax
    jnz .base
    call rt_exe_dir                 ; plik wykonywalny: jego folder
    lea rcx, [rax + 1]
    test rax, rax
    js .base_set
    mov [r15 + D_BASEFD], rcx
    jmp .base_set
.base:
    dec rax
.base_set:
    mov [rsp + 48], rax
.rules:
    mov r13d, [rbx + 4]
    add rbx, 8
.rule:
    test r13d, r13d
    jz .restrict
    mov rax, [rbx]
    test r12d, POL_COMMANDS
    jz .noexec
    or rax, 1                       ; EXECUTE
.noexec:
    and rax, r14
    mov [rsp + 32], rax
    lea rsi, [rbx + 10]
    mov edi, AT_FDCWD
    cmp byte [rsi], '/'
    je .open
    mov rdi, [rsp + 48]
    test rdi, rdi
    js .next                        ; brak folderu programu
.open:
    mov eax, SYS_OPENAT
    mov edx, O_PATH | O_CLOEXEC
    syscall
    test rax, rax
    js .next                        ; folderu nie ma: nic nie dostaje
    mov [rsp + 40], eax
    call .add
    cmp rax, -EINVAL
    jne .close
    and qword [rsp + 32], LL_FILE_RIGHTS
    jz .close
    call .add
.close:
    mov eax, SYS_CLOSE
    mov edi, [rsp + 40]
    syscall
.next:
    movzx eax, word [rbx + 8]
    lea rbx, [rbx + rax + 10]
    dec r13d
    jmp .rule
.restrict:
    call .nnp
    mov eax, SYS_LL_RESTRICT
    mov rdi, rbp
    xor esi, esi
    syscall
    mov eax, SYS_CLOSE
    mov rdi, rbp
    syscall
    mov r14d, 1                     ; Landlock działa
    jmp .limits
.ll_fail:
    xor r14d, r14d
.limits:
    ; limity zasobów (tanie, w przeciwieństwie do seccomp): bez commands —
    ; żadnych nowych procesów; bez żadnego importu — żadnych nowych deskryptorów
    ; (plików, gniazd, io_uring); otwarte wcześniej stdin/stdout/stderr działają
    xor eax, eax
    mov [rsp + 56], rax
    mov [rsp + 64], rax
    test r12d, POL_COMMANDS
    jnz .lim_fd
    mov eax, SYS_SETRLIMIT
    mov edi, RLIMIT_NPROC
    lea rsi, [rsp + 56]
    syscall
.lim_fd:
    test r12d, POL_FILES | POL_COMMANDS | POL_NET
    jnz .need_sec
    mov eax, SYS_SETRLIMIT
    mov edi, RLIMIT_NOFILE
    lea rsi, [rsp + 56]
    syscall
.need_sec:
    ; seccomp, gdy brak Landlock albo gdy pliki/polecenia są, a sieci nie
    ; (wtedy tylko seccomp zabrania gniazd)
    test r14d, r14d
    jz .seccomp
    test r12d, POL_NET
    jnz .done
    test r12d, POL_FILES | POL_COMMANDS
    jz .done
.seccomp:
    call .nnp
    lea rsi, [rt_filter]
    lea rdi, [rsp + 72]
    mov ecx, rt_filter_len
    rep movsb
    test r12d, POL_NET
    jz .f_cmd
    mov dword [rsp + 72 + 6*8 + 4], -1
.f_cmd:
    test r12d, POL_COMMANDS
    jz .f_load
    mov ecx, 7
.f_loop:
    mov dword [rsp + 72 + rcx*8 + 4], -1
    inc ecx
    cmp ecx, 13
    jb .f_loop
.f_load:
    mov word [rsp + 56], rt_filter_len / 8
    lea rax, [rsp + 72]
    mov [rsp + 64], rax
    mov eax, SYS_SECCOMP
    mov edi, 1                      ; SECCOMP_SET_MODE_FILTER
    xor esi, esi
    lea rdx, [rsp + 56]
    syscall
.done:
    add rsp, SB_FRAME
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
; landlock_add_rule(zbiór, PATH_BENEATH, [rsp + 32 wywołującego])
.add:
    mov eax, SYS_LL_ADD
    mov rdi, rbp
    mov esi, 1
    lea rdx, [rsp + 8 + 32]
    xor r10d, r10d
    syscall
    ret
.nnp:
    mov eax, SYS_PRCTL
    mov edi, PR_SET_NO_NEW_PRIVS
    mov esi, 1
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    syscall
    ret

; rt_exe_dir -> rax = deskryptor folderu pliku wykonywalnego albo < 0
rt_exe_dir:
    sub rsp, PATH_MAX
    mov eax, SYS_READLINKAT
    mov edi, AT_FDCWD
    lea rsi, [rt_str_exe]
    mov rdx, rsp
    mov r10d, PATH_MAX - 1
    syscall
    test rax, rax
    jle .fail
    mov rcx, rax
.find:
    dec rcx
    js .fail
    cmp byte [rsp + rcx], '/'
    jne .find
    mov byte [rsp + rcx + 1], 0
    mov eax, SYS_OPENAT
    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, O_PATH | O_DIRECTORY | O_CLOEXEC
    syscall
    add rsp, PATH_MAX
    ret
.fail:
    mov rax, -1
    add rsp, PATH_MAX
    ret

; filtr seccomp (BPF): kod, skok gdy prawda, gdy fałsz, argument
%macro BPF 4
    dw %1
    db %2, %3
    dd %4
%endmacro
align 8
rt_filter:
    BPF 0x20, 0, 0, 4               ; architektura
    BPF 0x15, 1, 0, 0xc000003e      ; x86-64?
    BPF 0x06, 0, 0, 0x80000000      ; inna: zabij proces
    BPF 0x20, 0, 0, 0               ; numer wywołania
    BPF 0x35, 10, 0, 0x40000000     ; x32: odmowa
    BPF 0x15, 9, 0, 425             ; io_uring_setup
    BPF 0x15, 8, 0, 41              ; socket (pozycja 6: net)
    BPF 0x15, 7, 0, 59              ; execve (pozycje 7-12: commands)
    BPF 0x15, 6, 0, 322             ; execveat
    BPF 0x15, 5, 0, 57              ; fork
    BPF 0x15, 4, 0, 58              ; vfork
    BPF 0x15, 3, 0, 56              ; clone
    BPF 0x15, 2, 0, 435             ; clone3
    BPF 0x15, 1, 0, 101             ; ptrace
    BPF 0x06, 0, 0, 0x7fff0000      ; zezwól
    BPF 0x06, 0, 0, 0x0005000d      ; odmowa: EACCES
rt_filter_len equ $ - rt_filter
rt_str_exe: db "/proc/self/exe", 0

rt_msg_prefix:  db "fih: błąd w linii "
rt_msg_prefix_len equ $ - rt_msg_prefix
rt_msg_ovf:     db "przepełnienie: wynik poza zakresem liczb 64-bitowych"
rt_msg_ovf_len  equ $ - rt_msg_ovf
rt_msg_div0:    db "dzielenie przez zero"
rt_msg_div0_len equ $ - rt_msg_div0
rt_msg_var1:    db "zmienna '"
rt_msg_var1_len equ $ - rt_msg_var1
rt_msg_var2:    db "' nie ma jeszcze wartości"
rt_msg_var2_len equ $ - rt_msg_var2
rt_msg_wfail:   db "fih: błąd: nie można zapisać wyjścia", 10
rt_msg_wfail_len equ $ - rt_msg_wfail
rt_msg_nl:      db 10
align 8
rt_end:

section .rodata
; przesunięcia funkcji od początku rt (dla generatora kodu)
rt_table:
    dd rt_end - rt_begin        ; RT_SIZE
    dd rt_write - rt_begin      ; RT_WRITE
    dd rt_int_nl - rt_begin     ; RT_INT_NL
    dd rt_exit - rt_begin       ; RT_EXIT
    dd rt_die - rt_begin        ; RT_DIE
    dd rt_die_var - rt_begin    ; RT_DIE_VAR
    dd rt_int - rt_begin        ; RT_INT
    dd rt_input - rt_begin      ; RT_INPUT
    dd rt_inputchar - rt_begin  ; RT_INPUTCHAR
    dd rt_sandbox - rt_begin    ; RT_SANDBOX
