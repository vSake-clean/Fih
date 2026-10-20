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

global rt_begin, rt_end, rt_table, rt_flt_fmt, rt_numcmp, rt_darith, rt_idiv_flt, rt_fmod, rt_fidiv
global parse_float, rt_math1, rt_math2

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

; rt_die(edi=linia, esi=rodzaj: 0 przepełnienie, 1 dzielenie przez zero,
; 2 indeks poza tekstem, 3 potrzebna liczba całkowita, 4 argument spoza
; dziedziny funkcji math, 5 wynik za duży)
rt_die:
    push rdi
    push rsi
    call rt_flush
    call rt_err_prefix
    pop rsi
    lea rcx, [rt_msg_tab]           ; dd przesunięcie od rt_begin, dd długość
    mov edx, [rcx + rsi*8 + 4]
    mov eax, [rcx + rsi*8]
    lea rcx, [rt_begin]
    add rax, rcx
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

; ===================== ułamki =====================
%include "rt_flt.inc"
%include "rt_dec.inc"
%include "rt_math.inc"

; ===================== teksty =====================
; Tekst w rejestrach: adres i długość w bajtach (UTF-8). Zmienna tekstowa
; trzyma wskaźnik do bloku: dq pojemność, dq długość, dane. Wyniki pośrednie
; (łączenie, liczba jako tekst, inputtext) trafiają do obszaru tymczasowego,
; czyszczonego po każdej instrukcji (rt_tmp_reset). Wycinki (t[i], t[a:b])
; nie kopiują: wskazują na fragment tekstu źródłowego.
%define BIG_BLOCK 65536             ; od tylu bajtów blok zmiennej ma własne mmap

; rt_mmap(rsi=rozmiar) -> rax = pamięć; zmienia rcx, rdx, rdi, r8-r11
rt_mmap:
    mov eax, SYS_MMAP
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae rt_nomem
    ret
rt_nomem:
    call rt_flush
    mov edi, STDERR
    lea rsi, [rt_msg_nomem]
    mov edx, rt_msg_nomem_len
    call rt_write_or_die
    jmp rt_exit1

; rt_copy(rdi=cel, rsi=źródło, rcx=n) — jak rep movsb (rdi, rsi za kopią,
; rcx = 0), ale szybciej dla krótkich tekstów; także gdy cel < źródło
; i się nakładają; zmienia r11, xmm0, xmm1
rt_copy:
    cmp rcx, 16
    ja .big
    cmp rcx, 8
    jb .small
    movq xmm0, [rsi]                ; 8-16 B: dwa nakładające się odczyty
    movq xmm1, [rsi + rcx - 8]
    movq [rdi], xmm0
    movq [rdi + rcx - 8], xmm1
.adv:
    add rsi, rcx
    add rdi, rcx
    xor ecx, ecx
    ret
.small:
    cmp rcx, 4
    jb .tiny
    movd xmm0, [rsi]
    movd xmm1, [rsi + rcx - 4]
    movd [rdi], xmm0
    movd [rdi + rcx - 4], xmm1
    jmp .adv
.tiny:
    test rcx, rcx
    jz .ret
    cmp rcx, 2
    jb .one
    movzx r11d, word [rsi]          ; 2-3 B: słowo i ostatni bajt
    mov [rdi], r11w
.one:
    movzx r11d, byte [rsi + rcx - 1]
    mov [rdi + rcx - 1], r11b
    jmp .adv
.ret:
    ret
.big:
    cmp rcx, 32
    ja .rep
    movdqu xmm0, [rsi]
    movdqu xmm1, [rsi + rcx - 16]
    movdqu [rdi], xmm0
    movdqu [rdi + rcx - 16], xmm1
    jmp .adv
.rep:
    rep movsb
    ret

; rt_tmp_alloc(rcx=n) -> rax = n bajtów w obszarze tymczasowym; zmienia r11
rt_tmp_alloc:
    mov rax, [r15 + D_TMPPTR]
    lea r11, [rax + rcx]
    cmp r11, [r15 + D_TMPEND]
    ja .new
    mov [r15 + D_TMPPTR], r11
    ret
.new:
    ; nowy kawałek: max(2 × poprzedni, n + nagłówek, 64 KB); poprzednie
    ; kawałki zostają do końca instrukcji (mogą w nich leżeć wyniki)
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    xor esi, esi
    mov rax, [r15 + D_TMPCHUNK]
    test rax, rax
    jz .size
    mov rsi, [rax + 8]
    add rsi, rsi
.size:
    lea rax, [rcx + 16 + 4095]
    and rax, -4096
    cmp rsi, rax
    cmovb rsi, rax
    mov eax, 65536
    cmp rsi, rax
    cmovb rsi, rax
    push rsi
    call rt_mmap
    pop rsi
    mov rcx, [r15 + D_TMPCHUNK]
    mov [rax], rcx
    mov [rax + 8], rsi
    mov [r15 + D_TMPCHUNK], rax
    add rsi, rax
    mov [r15 + D_TMPEND], rsi
    add rax, 16
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    lea r11, [rax + rcx]
    mov [r15 + D_TMPPTR], r11
    ret

; rt_tmp_reset — koniec instrukcji: obszar tymczasowy znów pusty (zostaje
; największy kawałek, starsze są zwalniane); zachowuje rax
rt_tmp_reset:
    mov rcx, [r15 + D_TMPCHUNK]
    test rcx, rcx
    jz .ret
    lea rdx, [rcx + 16]
    mov [r15 + D_TMPPTR], rdx
    mov rdx, [rcx]
    test rdx, rdx
    jz .ret
    mov qword [rcx], 0
    push rax
.free:
    mov rdi, rdx
    mov rsi, [rdx + 8]
    mov rdx, [rdx]
    mov eax, SYS_MUNMAP
    syscall
    test rdx, rdx
    jnz .free
    pop rax
.ret:
    ret

; rt_cat(rax, rdx = A; rcx, r8 = B) -> rax, rdx = A + B
rt_cat:
    test r8, r8
    jz .ret
    test rdx, rdx
    jz .b
    lea r9, [rax + rdx]
    cmp r9, [r15 + D_TMPPTR]
    jne .copy
    lea r10, [r9 + r8]
    cmp r10, [r15 + D_TMPEND]
    ja .copy
    ; A kończy się na szczycie obszaru tymczasowego: B dopisujemy w miejscu
    ; (łańcuch a + b + c kopiuje każdy kawałek raz)
    mov [r15 + D_TMPPTR], r10
    mov rdi, r9
    mov rsi, rcx
    mov rcx, r8
    call rt_copy
    add rdx, r8
    ret
.copy:
    push rax
    push rdx
    push rcx
    push r8
    lea rcx, [rdx + r8]
    call rt_tmp_alloc
    mov rdi, rax
    pop r8
    pop r9
    pop rcx
    pop rsi
    call rt_copy
    mov rsi, r9
    mov rcx, r8
    call rt_copy
    mov rdx, rdi
    sub rdx, rax
    ret
.b:
    mov rax, rcx
    mov rdx, r8
.ret:
    ret

; rt_fmt(rax=liczba ze znakiem, rsi=koniec bufora) -> rsi = początek zapisu
; dziesiętnego; po dwie cyfry (tablica par, dzielenie przez 100 mnożeniem);
; zmienia rax, rdx, r9, r10, r11
rt_fmt:
    mov r11, rax
    test rax, rax
    jns .pos
    neg rax                         ; INT64_MIN bez znaku daje poprawny moduł
.pos:
    lea r10, [rt_digits2]
.pair:
    cmp rax, 100
    jb .last
    mov r9, rax
    shr rax, 2                      ; n / 100 = ((n >> 2) × c) >> 66
    mov rdx, 0x28f5c28f5c28f5c3
    mul rdx
    shr rdx, 2
    imul rax, rdx, 100
    sub r9, rax                     ; reszta 0..99
    movzx eax, word [r10 + r9*2]
    sub rsi, 2
    mov [rsi], ax
    mov rax, rdx
    jmp .pair
.last:
    cmp eax, 10
    jb .one
    movzx eax, word [r10 + rax*2]
    sub rsi, 2
    mov [rsi], ax
    jmp .sign
.one:
    add al, '0'
    dec rsi
    mov [rsi], al
.sign:
    test r11, r11
    jns .ret
    dec rsi
    mov byte [rsi], '-'
.ret:
    ret

; rt_numlen(rax=liczba ze znakiem) -> r9 = długość zapisu dziesiętnego;
; cyfry = t + 1 - (n < 10^t), t = (bity(n) × 1233) >> 12; zmienia rax, r10, r11
rt_numlen:
    xor r9d, r9d
    mov r10, rax
    test r10, r10
    jns .pos
    neg r10
    inc r9d                         ; minus
.pos:
    or r10, 1                       ; 0 ma jedną cyfrę jak 1
    bsr r11, r10
    inc r11d
    imul r11d, r11d, 1233
    shr r11d, 12
    lea r9d, [r9 + r11 + 1]
    lea rax, [rt_pow10]
    cmp r10, [rax + r11*8]
    sbb r9d, 0
    ret

; rt_int2text(rax=liczba) -> rax, rdx = zapis dziesiętny; zachowuje rcx, r8
rt_int2text:
    push rcx
    push r8
    mov r8, rax
    call rt_numlen
    mov rcx, r9
    call rt_tmp_alloc
    push rax
    push r9
    lea rsi, [rax + r9]             ; cyfry od razu na miejscu, od końca
    mov rax, r8
    call rt_fmt
    pop rdx
    pop rax
    pop r8
    pop rcx
    ret

; rt_cat_int(rax, rdx = tekst A; rcx = liczba) -> rax, rdx = A + zapis liczby
; (cyfry pisane od razu na miejscu, bez tekstu pośredniego)
rt_cat_int:
    test rdx, rdx
    jnz .go
    mov rax, rcx
    jmp rt_int2text
.go:
    mov r8, rax
    mov rax, rcx
    call rt_numlen
    lea r10, [r8 + rdx]
    cmp r10, [r15 + D_TMPPTR]
    jne .copy
    lea r11, [r10 + r9]
    cmp r11, [r15 + D_TMPEND]
    ja .copy
    ; A na szczycie obszaru tymczasowego: cyfry zaraz za nim
    mov [r15 + D_TMPPTR], r11
    mov rsi, r11
    push rdx
    push r8
    push r9
    mov rax, rcx
    call rt_fmt
    pop r9
    pop rax
    pop rdx
    add rdx, r9
    ret
.copy:
    push rcx                        ; liczba
    push r9                         ; długość cyfr
    lea rcx, [rdx + r9]
    call rt_tmp_alloc
    mov rdi, rax
    mov rsi, r8
    mov rcx, rdx
    push rax
    call rt_copy                    ; A
    add rdi, [rsp + 8]              ; koniec wyniku
    mov rsi, rdi
    mov rax, [rsp + 16]
    call rt_fmt
    pop rax
    mov rdx, rdi
    sub rdx, rax
    add rsp, 16
    ret

; rt_heap_alloc(rcx=pojemność) -> rax = blok ([rax] = pojemność, może większa)
rt_heap_alloc:
    lea r11, [rcx + 16 + 7]
    and r11, -8
    cmp r11, BIG_BLOCK
    jae .big
    mov rax, [r15 + D_HEAPPTR]
    add r11, rax
    cmp r11, [r15 + D_HEAPEND]
    ja .chunk
    mov [r15 + D_HEAPPTR], r11
    sub r11, rax
    sub r11, 16
    mov [rax], r11
    ret
.chunk:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov esi, 1 << 20
    call rt_mmap
    mov [r15 + D_HEAPPTR], rax
    add rax, 1 << 20
    mov [r15 + D_HEAPEND], rax
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    jmp rt_heap_alloc
.big:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea rsi, [r11 + 4095]
    and rsi, -4096
    push rsi
    call rt_mmap
    pop rsi
    sub rsi, 16
    mov [rax], rsi
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rt_heap_free(rdi=blok albo 0) — duże bloki wracają do systemu, małe zostają
rt_heap_free:
    test rdi, rdi
    jz .ret
    mov rsi, [rdi]
    add rsi, 16
    cmp rsi, BIG_BLOCK
    jb .ret
    mov eax, SYS_MUNMAP
    syscall
.ret:
    ret

; rt_set_text(rdi=zmienna, rax, rdx = tekst) — kopia tekstu do bloku zmiennej
rt_set_text:
    mov r9, [rdi]
    test r9, r9
    jz .grow
    cmp rdx, [r9]
    ja .grow
    mov [r9 + 8], rdx
    lea rdi, [r9 + 16]
    cmp rdi, rax
    je .ret                         ; x = x
    mov rsi, rax                    ; źródło może leżeć w tym bloku (x = x[1:]):
    mov rcx, rdx                    ; kopia w przód jest wtedy poprawna
    call rt_copy
.ret:
    ret
.grow:
    xor ecx, ecx                    ; pojemność: max(długość, 2 × stara, 16)
    test r9, r9
    jz .g1
    mov rcx, [r9]
    add rcx, rcx
.g1:
    cmp rcx, rdx
    cmovb rcx, rdx
    mov r8d, 16
    cmp rcx, r8
    cmovb rcx, r8
    push rdi
    push rax
    push rdx
    push r9
    call rt_heap_alloc
    pop r9
    pop rdx
    pop rsi
    pop rdi
    mov [rdi], rax
    mov [rax + 8], rdx
    lea rdi, [rax + 16]
    mov rcx, rdx
    call rt_copy
    mov rdi, r9
    jmp rt_heap_free

; rt_append(rdi=zmienna, rax, rdx = tekst) — s += tekst, w miejscu gdy się mieści
rt_append:
    test rdx, rdx
    jz .ret
    mov r9, [rdi]
    mov r10, [r9 + 8]
    lea r11, [r10 + rdx]
    cmp r11, [r9]
    ja .grow
    mov [r9 + 8], r11
    lea rdi, [r9 + 16 + r10]        ; dopisany tekst może pochodzić z tego bloku
    mov rsi, rax                    ; (s += s[0:2]) — nie nachodzi na cel
    mov rcx, rdx
    cmp rdx, 3
    ja .copy
    add r10, 4
    cmp r10, [r9]
    ja .copy
    shr ecx, 1                      ; 1-3 B jednym zapisem 4 B (zapis za
    movzx r11d, byte [rsi + rdx - 1]    ; długością mieści się w pojemności);
    movzx ecx, byte [rsi + rcx]     ; dwa osobne zapisy są tu 2× wolniejsze
    movzx r10d, byte [rsi]
    shl r11d, 16
    shl ecx, 8
    or r11d, r10d
    or r11d, ecx
    mov [rdi], r11d
    ret
.copy:
    call rt_copy
.ret:
    ret
.grow:
    mov rcx, [r9]
    add rcx, rcx
    cmp rcx, r11
    cmovb rcx, r11
    mov r10, [r9]
    add r10, 16                     ; duży blok bez dopisku z wnętrza siebie:
    cmp r10, BIG_BLOCK              ; mremap zamiast kopii (jak realloc w C)
    jb .move
    mov r8, rax
    sub r8, r9
    cmp r8, r10
    jb .move
    push rdi
    push rax
    push rdx
    lea rdx, [rcx + 16 + 4095]
    and rdx, -4096
    push rdx
    mov rdi, r9
    mov rsi, r10
    mov r10d, MREMAP_MAYMOVE
    mov eax, SYS_MREMAP
    syscall
    cmp rax, -4095
    jae rt_nomem
    pop rcx
    sub rcx, 16
    mov [rax], rcx
    mov rcx, rax
    pop rdx
    pop rax
    pop rdi
    mov [rdi], rcx
    jmp rt_append
.move:
    push rdi
    push rax
    push rdx
    push r9
    call rt_heap_alloc
    pop r9
    pop rdx
    pop r8
    pop rdi
    mov [rdi], rax
    mov rcx, [r9 + 8]
    lea r11, [rcx + rdx]
    mov [rax + 8], r11
    lea rdi, [rax + 16]
    lea rsi, [r9 + 16]
    call rt_copy                       ; stara treść, potem dopisek (stary blok
    mov rsi, r8                     ; zwalniany na końcu: dopisek może w nim leżeć)
    mov rcx, rdx
    call rt_copy
    mov rdi, r9
    jmp rt_heap_free

; rt_streq(rax, rdx = A; rcx, r8 = B) -> rax = 1, gdy równe, inaczej 0
rt_streq:
    cmp rdx, r8
    jne .no
    mov rsi, rax
    mov rdi, rcx
    mov rcx, rdx
.word:
    cmp rcx, 8
    jb .tail
    mov r9, [rsi]
    cmp r9, [rdi]
    jne .no
    add rsi, 8
    add rdi, 8
    sub rcx, 8
    jmp .word
.tail:
    test rcx, rcx
    jz .yes
    mov r9b, [rsi]
    cmp r9b, [rdi]
    jne .no
    inc rsi
    inc rdi
    dec rcx
    jmp .tail
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; rt_len(rax, rdx) -> rax = liczba znaków (UTF-8: bajty, które nie są
; kontynuacją 10xxxxxx)
; po 8 bajtów: bajty kontynuacji to bit 7 = 1 i bit 6 = 0
rt_len:
    mov rsi, rax
    mov rcx, rdx
    mov rax, rdx                    ; wynik = bajty - bajty kontynuacji
    cmp rcx, 64
    jb .words
    movdqu xmm1, [rt_cont_lim]
    pxor xmm3, xmm3                 ; suma (dwa qword)
    pxor xmm5, xmm5
.block:                             ; po 16 B: bajt kontynuacji 0x80-0xbf to
    mov rdi, rcx                    ; ze znakiem -128..-65, czyli < -64
    shr rdi, 4
    jz .sum_done
    mov r9d, 255                    ; liczniki bajtowe najwyżej do 255
    cmp rdi, r9
    cmova rdi, r9
    pxor xmm2, xmm2
.vec:
    movdqu xmm0, [rsi]
    movdqa xmm4, xmm1
    pcmpgtb xmm4, xmm0
    psubb xmm2, xmm4
    add rsi, 16
    sub rcx, 16
    dec rdi
    jnz .vec
    psadbw xmm2, xmm5
    paddq xmm3, xmm2
    jmp .block
.sum_done:
    movq r9, xmm3
    sub rax, r9
    punpckhqdq xmm3, xmm3
    movq r9, xmm3
    sub rax, r9
.words:
    mov r9, 0x8080808080808080
    mov r10, 0x0101010101010101
.word:
    cmp rcx, 8
    jb .tail
    mov rdi, [rsi]
    lea r11, [rdi + rdi]            ; bit 6 każdego bajtu na miejsce bitu 7
    not r11
    and r11, rdi
    and r11, r9
    shr r11, 7
    imul r11, r10                   ; suma bajtów w najwyższym bajcie
    shr r11, 56
    sub rax, r11
    add rsi, 8
    sub rcx, 8
    jmp .word
.tail:
    test rcx, rcx
    jz .ret
    movzx edi, byte [rsi]
    and edi, 0xc0
    cmp edi, 0x80
    jne .next
    dec rax
.next:
    inc rsi
    dec rcx
    jmp .tail
.ret:
    ret

; rt_skip(rsi=pozycja, rdi=koniec, rcx=ile znaków) -> rsi za nimi,
; rcx = ile się nie zmieściło; zmienia r11
rt_skip:
    test rcx, rcx
    jz .ret
    lea r11, [rsi + 8]              ; 8 bajtów ASCII (bit 7 = 0): 8 znaków naraz
    cmp r11, rdi
    ja .char
    mov r11, 0x8080808080808080
    and r11, [rsi]
    jnz .char
    cmp rcx, 8
    jb .part
    add rsi, 8
    sub rcx, 8
    jmp rt_skip
.part:
    add rsi, rcx
    xor ecx, ecx
    ret
.char:
    cmp rsi, rdi
    jae .ret
    inc rsi
.cont:
    cmp rsi, rdi
    jae .next
    movzx r11d, byte [rsi]
    and r11d, 0xc0
    cmp r11d, 0x80
    jne .next
    inc rsi
    jmp .cont
.next:
    dec rcx
    jnz rt_skip
.ret:
    ret

; rt_index(rax, rdx = tekst, rcx = i) -> rax, rdx = znak nr i (od 0, ujemne
; od końca); CF = 1, gdy poza tekstem
rt_index:
    test rcx, rcx
    jns .pos
    push rax
    push rdx
    push rcx
    call rt_len
    pop rcx
    pop rdx
    add rcx, rax
    pop rax
    test rcx, rcx
    js .bad
.pos:
    mov rsi, rax
    lea rdi, [rax + rdx]
    call rt_skip
    test rcx, rcx
    jnz .bad
    cmp rsi, rdi
    jae .bad
    mov rax, rsi
    mov ecx, 1
    call rt_skip
    mov rdx, rsi
    sub rdx, rax
    clc
    ret
.bad:
    stc
    ret

; rt_slice(rax, rdx = tekst, rcx = od, r8 = do) -> rax, rdx = znaki [od, do)
; jak w Pythonie: ujemne od końca, poza zakresem przycinane
rt_slice:
    mov r9, rcx
    or r9, r8
    jns .forward                    ; od, do >= 0: bez liczenia całego tekstu
    push rax
    push rdx
    push rcx
    push r8
    call rt_len
    pop r8
    pop rcx
    pop rdx
    pop rsi
    mov r9, rcx
    test r9, r9
    jns .a1
    add r9, rax
    jns .a1
    xor r9d, r9d
.a1:
    cmp r9, rax
    jbe .a2
    mov r9, rax
.a2:
    mov r10, r8
    test r10, r10
    jns .b1
    add r10, rax
    jns .b1
    xor r10d, r10d
.b1:
    cmp r10, rax
    jbe .b2
    mov r10, rax
.b2:
    cmp r10, r9
    jae .b3
    mov r10, r9
.b3:
    lea rdi, [rsi + rdx]
    mov rcx, r9
    call rt_skip
    jmp .rest
.forward:
    ; przycinanie wynika z rt_skip (zatrzymuje się na końcu tekstu)
    mov rsi, rax
    lea rdi, [rax + rdx]
    mov r9, rcx
    mov r10, r8
    cmp r10, r9
    jae .f_skip
    mov r10, r9
.f_skip:
    call rt_skip
.rest:
    mov rax, rsi
    mov rcx, r10
    sub rcx, r9
    call rt_skip
    mov rdx, rsi
    sub rdx, rax
    ret

; rt_inputtext -> rax, rdx = linia wejścia (bez '\n' i końcowego '\r');
; inputok() = 1, gdy przeczytano linię; po końcu wejścia pusty tekst
rt_inputtext:
    call rt_readline
    test eax, eax
    jnz .eof
    mov qword [r15 + D_INOK], 0
    cmp rdx, -1
    je .empty                       ; linia od 64 KB: jak zły wpis
    test rdx, rdx
    jz .ok
    cmp byte [rsi + rdx - 1], 13
    jne .ok
    dec rdx
.ok:
    mov qword [r15 + D_INOK], 1
    mov rcx, rdx
    call rt_tmp_alloc
    mov rdi, rax
    mov rcx, rdx
    call rt_copy
    ret
.eof:
    call rt_in_eof
.empty:
    lea rax, [rt_begin]
    xor edx, edx
    ret

; rt_nl — wypisuje '\n'
rt_nl:
    lea rsi, [rt_msg_nl]
    mov edx, 1
    jmp rt_write

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
rt_msg_index:   db "indeks poza tekstem"
rt_msg_index_len equ $ - rt_msg_index
rt_msg_int:     db "tu potrzebna jest liczba całkowita"
rt_msg_int_len  equ $ - rt_msg_int
rt_msg_dom:     db "argument spoza dziedziny funkcji matematycznej"
rt_msg_dom_len  equ $ - rt_msg_dom
rt_msg_rng:     db "wynik za duży, by zapisać go jako ułamek"
rt_msg_rng_len  equ $ - rt_msg_rng
; komunikaty rt_die według rodzaju (esi)
rt_msg_tab:
    dd rt_msg_ovf - rt_begin, rt_msg_ovf_len
    dd rt_msg_div0 - rt_begin, rt_msg_div0_len
    dd rt_msg_index - rt_begin, rt_msg_index_len
    dd rt_msg_int - rt_begin, rt_msg_int_len
    dd rt_msg_dom - rt_begin, rt_msg_dom_len
    dd rt_msg_rng - rt_begin, rt_msg_rng_len
rt_msg_nomem:   db "fih: błąd: brak pamięci", 10
rt_msg_nomem_len equ $ - rt_msg_nomem
rt_msg_var1:    db "zmienna '"
rt_msg_var1_len equ $ - rt_msg_var1
rt_msg_var2:    db "' nie ma jeszcze wartości"
rt_msg_var2_len equ $ - rt_msg_var2
rt_msg_wfail:   db "fih: błąd: nie można zapisać wyjścia", 10
rt_msg_wfail_len equ $ - rt_msg_wfail
rt_msg_nl:      db 10
align 16
rt_cont_lim: times 16 db -64
rt_pow10:                           ; 10^0 .. 10^19
    dq 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000
    dq 1000000000, 10000000000, 100000000000, 1000000000000, 10000000000000
    dq 100000000000000, 1000000000000000, 10000000000000000
    dq 100000000000000000, 1000000000000000000, 0x8ac7230489e80000
rt_digits2:
%assign i 0
%rep 100
    db '0' + i / 10, '0' + i % 10
%assign i i + 1
%endrep
align 8
%include "flt_tab.inc"
%include "trig_tab.inc"
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
    dd rt_tmp_reset - rt_begin  ; RT_TMPRESET
    dd rt_cat - rt_begin        ; RT_CAT
    dd rt_int2text - rt_begin   ; RT_INT2TEXT
    dd rt_set_text - rt_begin   ; RT_SETTEXT
    dd rt_append - rt_begin     ; RT_APPEND
    dd rt_streq - rt_begin      ; RT_STREQ
    dd rt_len - rt_begin        ; RT_LEN
    dd rt_index - rt_begin      ; RT_INDEX
    dd rt_slice - rt_begin      ; RT_SLICE
    dd rt_inputtext - rt_begin  ; RT_INPUTTEXT
    dd rt_nl - rt_begin         ; RT_NL
    dd rt_cat_int - rt_begin    ; RT_CATINT
    dd rt_flt_out - rt_begin    ; RT_FLT_OUT
    dd rt_flt_out_nl - rt_begin ; RT_FLT_OUT_NL
    dd rt_num_out - rt_begin    ; RT_NUM_OUT
    dd rt_num_out_nl - rt_begin ; RT_NUM_OUT_NL
    dd rt_flt2text - rt_begin   ; RT_FLT2TEXT
    dd rt_num2text - rt_begin   ; RT_NUM2TEXT
    dd rt_numcmp - rt_begin     ; RT_NUMCMP
    dd rt_darith - rt_begin     ; RT_DARITH
    dd rt_idiv_flt - rt_begin   ; RT_IDIVF
    dd rt_fmod - rt_begin       ; RT_FMOD
    dd rt_fidiv - rt_begin      ; RT_FIDIV
    dd rt_math1 - rt_begin      ; RT_MATH1
    dd rt_math2 - rt_begin      ; RT_MATH2
    dd rt_random - rt_begin     ; RT_RANDOM
