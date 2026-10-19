; interp.asm — wykonywanie programu linia po linii
;
; Każda linia to: pusta | # komentarz | instrukcja("napis") [# komentarz]
;   print("...")  wypisuje napis dosłownie (obsługuje \n \t \\ \")
;   calc("...")   liczy wyrażenie całkowite i wypisuje wynik
%include "fih.inc"
default rel

global run, cur_line
extern out_write, out_write_nl, out_byte, out_int_nl, die, eval_expr, eval_expr_soft

%define PRECOMPUTED -1      ; r12: calc już policzony szybką ścieżką (wynik w r9)

section .bss
cur_line: resq 1

section .rodata
align 16
rep_quote:     times 16 db '"'
rep_backslash: times 16 db '\'
rep_newline:   times 16 db 10
name_calc:     db "calc"

; IDENT_CHAR — 1 dla [A-Za-z0-9_]
ident_tab:
%assign i 0
%rep 256
  %if (i >= '0' && i <= '9') || (i >= 'A' && i <= 'Z') || (i >= 'a' && i <= 'z') || i == '_'
    db 1
  %else
    db 0
  %endif
  %assign i i+1
%endrep

; NEXT_LINE — koniec szybkiej ścieżki: r14 stoi na początku następnej linii;
; gdy zaczyna się ona od zwykłego znaku, od razu rozpoznajemy nazwę
%macro NEXT_LINE 0
    cmp r14, r15
    jae .line
    movzx eax, byte [r14]
    cmp al, ' '
    jbe .line
    cmp al, '#'
    jne .ident_start
    jmp .line
%endmacro

; SKIP_BLANK — przesuwa r14 za spacje, tabulatory i '\r' (zmienia tylko eax)
%macro SKIP_BLANK 0
    cmp r14, r15
    jae %%done
    cmp byte [r14], ' '
    ja %%done               ; zwykle od razu znak > ' ' — 4 instrukcje
%%loop:
    cmp r14, r15
    jae %%done
    movzx eax, byte [r14]
    cmp al, ' '
    je %%skip
    cmp al, 9
    je %%skip
    cmp al, 13
    jne %%done
%%skip:
    inc r14
    jmp %%loop
%%done:
%endmacro

section .text

; run(rdi=kod, rsi=długość, rdx=numer pierwszej linii)
; r14 = kursor, r15 = koniec kodu, rbx = nazwa instrukcji, r12 = jej długość,
; r13/rbp = początek/koniec treści napisu
run:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r14, rdi
    lea r15, [rdi+rsi]
    mov [cur_line], rdx
    movdqa xmm8, [rep_quote]
    movdqa xmm9, [rep_backslash]
    movdqa xmm10, [rep_newline]

.line:
    SKIP_BLANK
    cmp r14, r15
    jae .done
    movzx eax, byte [r14]
    cmp al, 10
    je .newline
    cmp al, '#'
    je .comment

    ; nazwa instrukcji: [A-Za-z_][A-Za-z0-9_]*
.ident_start:
    mov rbx, r14
    lea rdx, [ident_tab]
    ; szybka ścieżka: "print" / "calc", po których nie ma znaku nazwy
    mov rcx, r15
    sub rcx, r14
    cmp rcx, 6
    jb .ident_slow
    mov ecx, [r14]
    cmp ecx, 'prin'
    jne .try_calc
    cmp byte [r14+4], 't'
    jne .ident_slow
    movzx ecx, byte [r14+5]
    cmp byte [rdx+rcx], 0
    jne .ident_slow
    mov r12d, 5
    ; print(" bez spacji — od razu do skanowania napisu
    lea rax, [r14+7]
    cmp rax, r15
    ja .print_generic
    cmp word [r14+5], '("'
    jne .print_generic
    add r14, 7
    mov r13, r14
    jmp .str_start
.print_generic:
    add r14, 5
    jmp .ident_done
.try_calc:
    cmp ecx, 'calc'
    jne .ident_slow
    movzx ecx, byte [r14+4]
    cmp byte [rdx+rcx], 0
    jne .ident_slow
    ; najprostszy zapis calc("...")\n w jednym przebiegu; każdy inny
    ; (spacje, komentarz, błąd) idzie zwykłą ścieżką od początku linii
    lea rax, [r14+8]
    cmp rax, r15
    ja .calc_generic
    cmp word [r14+4], '("'
    jne .calc_generic
    cmp byte [r15-1], 10    ; granica [r15-1] nie może należeć do wyrażenia
    jne .calc_generic
    lea rdi, [r14+6]
    lea rsi, [r15-1]
    call eval_expr_soft
    jc .calc_generic
    cmp byte [rdx+1], ')'
    jne .calc_generic
    cmp byte [rdx+2], 10
    jne .calc_generic
    lea r14, [rdx+3]
    inc qword [cur_line]
    mov rdi, rax
    call out_int_nl
    NEXT_LINE
.calc_generic:
    mov rbx, r14            ; ewaluator mógł zmienić rbx/r12/r13
    mov r12d, 4
    add r14, 4
    jmp .ident_done
.ident_slow:
    sub eax, '0'
    cmp eax, 9
    jbe err_char
.ident:
    cmp r14, r15
    jae .ident_end
    movzx eax, byte [r14]
    cmp byte [rdx+rax], 0
    je .ident_end
    inc r14
    jmp .ident
.ident_end:
    mov r12, r14
    sub r12, rbx
    jz err_char
.ident_done:
    SKIP_BLANK
    cmp r14, r15
    jae err_lparen
    cmp byte [r14], '('
    jne err_lparen
    inc r14

    SKIP_BLANK
    cmp r14, r15
    jae err_string
    cmp byte [r14], '"'
    jne err_string
    inc r14
    mov r13, r14
    ; szybka ścieżka calc: liczymy od razu, parser sam znajduje '"';
    ; przy jakimkolwiek kłopocie zwykła ścieżka (te same komunikaty błędów)
    cmp r12, 4
    jne .str_start
    cmp dword [rbx], 'calc'
    jne .str_start
    mov rax, r15
    sub rax, r14
    cmp rax, 2
    jb .str_start
    cmp byte [r15-1], 10    ; granica [r15-1] nie może należeć do wyrażenia
    jne .str_start          ; (plik bez '\n' na końcu: zwykła ścieżka)
    mov rdi, r14
    lea rsi, [r15-1]
    call eval_expr_soft
    jc .calc_slow
    mov r9, rax
    mov rbp, rdx
    lea r14, [rdx+1]
    mov r12, PRECOMPUTED
    jmp .after_string
.calc_slow:
    ; ewaluator zmienił rbx/r12/r13 — odtwarzamy (nazwa to na pewno "calc")
    lea rbx, [name_calc]
    mov r12d, 4
    mov r13, r14
.str_start:
    xor r9d, r9d            ; r9 = 1, gdy napis zawiera '\'
.str:
    ; szukamy '"', '\' lub '\n' po 16 bajtów naraz (SSE2)
    mov rax, r15
    sub rax, r14
    cmp rax, 16
    jb .str_byte
    movdqu xmm0, [r14]
    movdqa xmm1, xmm0
    pcmpeqb xmm1, xmm8
    movdqa xmm2, xmm0
    pcmpeqb xmm2, xmm9
    pcmpeqb xmm0, xmm10
    por xmm1, xmm2
    por xmm1, xmm0
    pmovmskb eax, xmm1
    test eax, eax
    jnz .str_hit
    add r14, 16
    jmp .str
.str_hit:
    bsf eax, eax
    add r14, rax
.str_byte:
    cmp r14, r15
    jae err_unterminated
    movzx eax, byte [r14]
    cmp al, '"'
    je .str_end
    cmp al, 10
    je err_unterminated
    inc r14
    cmp al, '\'
    jne .str
    ; sekwencja ucieczki — pomijamy znak po '\'
    mov r9d, 1
    cmp r14, r15
    jae err_unterminated
    cmp byte [r14], 10
    je err_unterminated
    inc r14
    jmp .str
.str_end:
    mov rbp, r14
    inc r14
    ; najprostszy koniec print("...")\n bez '\' w napisie — tu żaden błąd nie
    ; jest możliwy, więc od razu wypisujemy i przechodzimy do następnej linii
    cmp r12, 5
    jne .after_string
    cmp dword [rbx], 'prin'     ; nazwa to naprawdę "print" (nie np. "Print")
    jne .after_string
    cmp byte [rbx+4], 't'
    jne .after_string
    test r9d, r9d
    jnz .after_string
    lea rax, [r14+1]
    cmp rax, r15
    jae .after_string
    cmp word [r14], 0x0a29  ; ")\n"
    jne .after_string
    add r14, 2
    inc qword [cur_line]
    mov rdi, r13
    mov rsi, rbp
    sub rsi, rdi
    call out_write_nl
    NEXT_LINE
.after_string:

    SKIP_BLANK
    cmp r14, r15
    jae err_rparen
    cmp byte [r14], ')'
    jne err_rparen
    inc r14

    ; po instrukcji może być tylko koniec linii albo komentarz
    SKIP_BLANK
    cmp r14, r15
    jae .exec
    movzx eax, byte [r14]
    cmp al, 10
    je .exec
    cmp al, '#'
    jne err_trailing

.exec:
    cmp r12, PRECOMPUTED
    je .calc_done
    cmp r12, 5
    jne .not_print
    cmp dword [rbx], 'prin'
    jne err_unknown
    cmp byte [rbx+4], 't'
    jne err_unknown
    mov rdi, r13
    mov rsi, rbp
    test r9d, r9d
    jnz .print_escaped
    sub rsi, rdi            ; bez '\' — wypisujemy napis w całości
    call out_write_nl
    jmp .line
.print_escaped:
    call print_string
.print_nl:
    mov edi, 10
    call out_byte
    jmp .line

.not_print:
    cmp r12, 4
    jne err_unknown
    cmp dword [rbx], 'calc'
    jne err_unknown
    mov rdi, r13
    mov rsi, rbp
    call eval_expr
    mov rdi, rax
    call out_int_nl
    jmp .line
.calc_done:
    mov rdi, r9
    call out_int_nl
    jmp .line

.comment:
    cmp r14, r15
    jae .done
    cmp byte [r14], 10
    je .newline
    inc r14
    jmp .comment

.newline:
    inc r14
    inc qword [cur_line]
    jmp .line

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; print_string(rdi=początek, rsi=koniec) — wypisuje treść napisu,
; rozwijając sekwencje ucieczki (poprawność końca sprawdził już run)
print_string:
    push rbx
    push r12
    push r13
    mov rbx, rdi            ; początek bieżącego fragmentu
    mov r12, rdi            ; kursor
    mov r13, rsi            ; koniec
.loop:
    cmp r12, r13
    jae .finish
    cmp byte [r12], '\'
    je .escape
    inc r12
    jmp .loop
.escape:
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    call out_write
    movzx eax, byte [r12+1]
    mov edi, 10
    cmp al, 'n'
    je .put
    mov edi, 9
    cmp al, 't'
    je .put
    mov edi, eax
    cmp al, '\'
    je .put
    cmp al, '"'
    jne err_escape
.put:
    call out_byte
    add r12, 2
    mov rbx, r12
    jmp .loop
.finish:
    mov rdi, rbx
    mov rsi, r13
    sub rsi, rbx
    call out_write
    pop r13
    pop r12
    pop rbx
    ret

ERR err_char,         "nieoczekiwany znak na początku instrukcji"
ERR err_lparen,       "oczekiwano '(' po nazwie instrukcji"
ERR err_string,       "oczekiwano napisu w cudzysłowie"
ERR err_unterminated, "niezamknięty napis"
ERR err_rparen,       "oczekiwano ')' po napisie"
ERR err_trailing,     "nieoczekiwane znaki po instrukcji"
ERR err_unknown,      "nieznana instrukcja (znane: print, calc)"
ERR err_escape,       'nieznana sekwencja ucieczki (znane: \n \t \\ \")'
