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

; rt_int_nl(rax=liczba ze znakiem) — wypisuje liczbę i '\n'
rt_int_nl:
    sub rsp, 40
    lea rsi, [rsp + 32]
    mov byte [rsi], 10
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
    lea rdx, [rsp + 33]
    sub rdx, rsi
    call rt_write
    add rsp, 40
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
