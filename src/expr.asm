; expr.asm — wyrażenia całkowite (int64) dla calc("...")
;
;   expr   = term   (('+' | '-') term)*
;   term   = factor (('*' | '/' | '%') factor)*
;   factor = ('-' | '+')* (liczba | '(' expr ')')
;
; Przepełnienie (+ - *, unarny minus, INT64_MIN / -1) jest błędem; / obcina
; w stronę zera, % ma znak dzielnej. Oba poziomy priorytetu liczone są w jednej pętli
; (eval_sum); rekurencja jest tylko dla nawiasów.
;
; Rejestry w całym module: r12 = kursor, r13 = koniec wyrażenia,
; rbx = suma, rbp = bieżący składnik, rsi = oczekujący '+'/'-',
; rdi = parzystość minusów przed czynnikiem,
; r8/r10/r11 = stałe SWAR 0x76…76 / 0x80…80 / 0x30…30 (LOAD_SWAR).
; Niezmiennik: bajt [r13] nigdy nie może należeć do wyrażenia (cyfra, operator,
; nawias, spacja) — w trybie zwykłym to zamykający '"', w trybie na próbę
; sprawdza to wywołujący. Dzięki temu pętle zatrzymują się na nim same i nie
; trzeba porównywać kursora z końcem przy każdym znaku.
; Moduł zmienia rbx, rbp, r12, r13 i nie zapisuje ich — wywołujący (interp)
; ich po obliczeniu nie potrzebuje; r14 i r15 zostają nietknięte.
%include "fih.inc"
default rel

global eval_expr, eval_expr_soft, expr_init, stack_budget
extern die

; ile stosu mogą zużyć nawiasy (najwyżej 1/4 limitu stosu procesu)
%define STACK_BUDGET (1 << 20)

; rzadko wykonywany kod (wolne ścieżki makr) — osobno, żeby gorące pętle
; nie musiały go przeskakiwać
section .text.cold progbits alloc exec nowrite align=16

section .data
stack_budget: dq STACK_BUDGET

section .bss
stack_floor: resq 1
swar_end:    resq 1         ; od tej pozycji nie wolno czytać 8 bajtów naraz
soft_rsp:    resq 1         ; != 0: tryb "na próbę" — błąd wraca do eval_expr_soft

; EERR etykieta, "komunikat" — jak ERR, ale w trybie na próbę zamiast
; kończyć program wraca z eval_expr_soft z CF=1
%macro EERR 2
%1:
    lea rdi, [%%msg]
    mov esi, %%len
    jmp expr_error
[section .rodata]
%%msg: db %2
%%len equ $ - %%msg
__SECT__
%endmacro

; SKIP_WS — pomija spacje i tabulatory (wstawiane w miejscu, zmienia tylko ecx).
; Pojedyncza spacja jest przeskakiwana bez skoku (sete), bo to najczęstszy
; przypadek, a skok warunkowy byłby źle przewidywany. Odczyt [r12] przy
; r12 == r13 jest bezpieczny: r13 wskazuje zamykający cudzysłów napisu.
%macro SKIP_WS 0
    xor ecx, ecx
    cmp byte [r12], ' '
    sete cl
    add r12, rcx
    cmp byte [r12], ' '
    jbe %%slow              ; rzadkie — kod poza gorącą ścieżką, bez skoku tutaj
%%back:
[section .text.cold]
%%slow:
    cmp r12, r13
    jae %%back
    mov cl, [r12]
    cmp cl, ' '
    je %%skip
    cmp cl, 9
    jne %%back
%%skip:
    inc r12
    jmp %%slow
__SECT__
%endmacro

; LOAD_SWAR — stałe SWAR do rejestrów i granica odczytu 8 bajtów (r13 - 8)
%macro LOAD_SWAR 0
    mov r8, 0x7676767676767676
    mov r10, 0x8080808080808080
    mov r11, 0x3030303030303030
    lea rax, [r13 - 8]
    mov [swar_end], rax
%endmacro

section .text

; expr_init() — dopasowuje budżet stosu do limitu procesu (ulimit -s):
; najwyżej 1/4 limitu, żeby rekurencja nigdy nie wyszła poza stos
expr_init:
    sub rsp, 16
    mov eax, SYS_GETRLIMIT
    mov edi, RLIMIT_STACK
    mov rsi, rsp
    syscall
    test rax, rax
    jnz .done
    mov rcx, [rsp]          ; rlim_cur (RLIM_INFINITY = -1)
    shr rcx, 2
    cmp rcx, [stack_budget]
    jae .done
    mov [stack_budget], rcx
.done:
    add rsp, 16
    ret

; eval_expr(rdi=początek, rsi=koniec) -> rax = wynik
eval_expr:
    mov r12, rdi
    mov r13, rsi
    mov rax, rsp
    sub rax, [stack_budget]
    mov [stack_floor], rax
    LOAD_SWAR
    call eval_sum           ; kończy z pominiętymi spacjami
    cmp r12, r13
    jb err_unexpected
    mov rax, rbx
    ret

; eval_expr_soft(rdi=początek, rsi=granica) -> CF=0: rax = wynik, rdx = pozycja
; zamykającego '"'; CF=1: nie udało się (błąd, znak spoza wyrażenia, brak '"')
; Liczy wyrażenie bez wcześniejszego szukania końca napisu. Bajt [rsi] musi
; być czytelny. Nie wypisuje niczego i nie kończy programu.
eval_expr_soft:
    mov r12, rdi
    mov r13, rsi
    mov rax, rsp
    sub rax, [stack_budget]
    mov [stack_floor], rax
    LOAD_SWAR
    mov [soft_rsp], rsp     ; wskazuje adres powrotu — błąd wraca stąd
    call eval_sum
    mov qword [soft_rsp], 0
    cmp r12, r13
    jae .fail
    cmp byte [r12], '"'
    jne .fail
    mov rax, rbx
    mov rdx, r12
    clc
    ret
.fail:
    stc
    ret

; expr_error — błąd wyrażenia: w trybie na próbę powrót z CF=1, inaczej die
expr_error:
    mov rax, [soft_rsp]
    test rax, rax
    jz die
    mov rsp, rax
    mov qword [soft_rsp], 0
    stc
    ret

; eval_sum -> rbx — suma składników; kończy się na końcu, ')' lub innym znaku,
; zawsze z kursorem za spacjami
eval_sum:
    xor ebx, ebx
    xor esi, esi            ; maska znaku składnika: 0 = '+', -1 = '-'
.term:
    call factor
    mov rbp, rax
.mul_loop:
    ; najczęstszy zapis "x OP y": spacja, operator, spacja, znak > ' ' — jeden
    ; odczyt 4 bajtów i kursor +3, bez łańcucha zależności przez SKIP_WS
    cmp r12, [swar_end]
    ja .mul_loop_slow
    mov edx, [r12]
    mov ecx, edx
    and ecx, 0x00ff00ff
    cmp ecx, 0x00200020
    jne .mul_loop_slow
    cmp edx, 0x21000000
    jb .mul_loop_slow
    shr edx, 8
    cmp dl, '*'
    je .q_mul
    cmp dl, '+'
    je .q_add
    cmp dl, '-'
    je .q_sub
    cmp dl, '/'
    je .q_div
    cmp dl, '%'
    je .q_mod
.mul_loop_slow:
    SKIP_WS
    mov cl, [r12]
    cmp cl, '*'
    je .mul
    cmp cl, '/'
    je .div
    cmp cl, '%'
    je .mod
.term_end:
    ; suma += składnik albo -= składnik, bez skoku: przy masce -1 liczymy
    ; rbx + ~rbp + 1 (adc z przeniesieniem 1) — flaga OF jest wtedy taka jak
    ; przy zwykłym odejmowaniu, więc przepełnienie wykrywa jedno jo
    xor rbp, rsi
    mov rcx, rsi
    neg rcx
    adc rbx, rbp
    jo err_overflow
    ; spacje pominęła już pętla mnożenia (mul_loop)
    movzx ecx, byte [r12]
    xor esi, esi
    cmp cl, '+'
    je .next_term
    cmp cl, '-'
    jne .done
    dec rsi
.next_term:
    inc r12
    jmp .term
.done:
    ret
.q_mul:
    add r12, 3
    call factor_ns
    imul rbp, rax
    jo err_overflow
    jmp .mul_loop
.q_div:
    add r12, 3
    call factor_ns
    mov rcx, rax
    mov rax, rbp
    call divide
    jc err_overflow
    mov rbp, rax
    jmp .mul_loop
.q_mod:
    add r12, 3
    call factor_ns
    mov rcx, rax
    mov rax, rbp
    call divide
    mov rbp, rdx
    jmp .mul_loop
.q_sub:
    xor rbp, rsi
    mov rcx, rsi
    neg rcx
    adc rbx, rbp
    jo err_overflow
    mov rsi, -1
    add r12, 3
    call factor_ns
    mov rbp, rax
    jmp .mul_loop
.q_add:
    xor rbp, rsi
    mov rcx, rsi
    neg rcx
    adc rbx, rbp
    jo err_overflow
    xor esi, esi
    add r12, 3
    call factor_ns
    mov rbp, rax
    jmp .mul_loop
.mul:
    inc r12
    call factor
    imul rbp, rax
    jo err_overflow
    jmp .mul_loop
.div:
    inc r12
    call factor
    mov rcx, rax
    mov rax, rbp
    call divide
    jc err_overflow
    mov rbp, rax
    jmp .mul_loop
.mod:
    inc r12
    call factor
    mov rcx, rax
    mov rax, rbp
    call divide
    mov rbp, rdx
    jmp .mul_loop

; divide(rax=dzielna, rcx=dzielnik) -> rax = iloraz, rdx = reszta,
; CF = 1 gdy iloraz się nie mieści (INT64_MIN / -1) — sprawdza tylko '/' 
divide:
    test rcx, rcx
    jz err_div_zero
    cmp rcx, -1
    je .minus_one           ; INT64_MIN / -1 wywołałoby wyjątek procesora
    ; gdy obie liczby mieszczą się w 32 bitach, idiv r32 jest dużo szybszy
    movsxd r9, eax
    cmp r9, rax
    jne .wide
    movsxd r9, ecx
    cmp r9, rcx
    jne .wide
    cdq
    idiv ecx
    movsxd rax, eax
    movsxd rdx, edx
    clc
    ret
.wide:
    cqo
    idiv rcx
    clc
    ret
.minus_one:
    xor edx, edx            ; x % -1 = 0; x / -1 = -x (INT64_MIN / -1 to przepełnienie)
    neg rax
    jo .minus_one_ovf
    clc
    ret
.minus_one_ovf:
    stc
    ret

; factor -> rax — znaki '+'/'-', potem liczba albo wyrażenie w nawiasie
; factor_ns — jak factor, gdy kursor stoi już na znaku > ' ' (bez SKIP_WS)
factor_ns:
    xor edi, edi
    jmp factor.body

factor:
    xor edi, edi
.sign:
    SKIP_WS
.body:
    movzx ecx, byte [r12]
    sub ecx, '0'
    cmp ecx, 9
    ja .not_digit           ; najczęściej cyfra — sprawdzana jako pierwsza
    cmp r12, [swar_end]
    ja .scalar
    ; SWAR: 8 bajtów naraz — długość ciągu cyfr i jego wartość bez pętli
    mov r9, [r12]
    sub r9, r11             ; bajty-cyfry -> 0..9
    lea rdx, [r9 + r8]
    or rdx, r9              ; bit 7 bajtu = nie-cyfra (> 9 albo < 0)
    and rdx, r10
    jz .scalar              ; 8+ cyfr — rzadkie, zwykła pętla
    bsf rdx, rdx
    shr edx, 3              ; liczba cyfr (1..7)
    ; osobna ścieżka dla każdej krótkiej długości: kursor przesuwa się o stałą,
    ; więc przy trafionym przewidywaniu skoku procesor nie czeka na bsf
    cmp edx, 4
    jne .not4
    add r12, 4
    imul eax, r9d, 10 * 256 + 1     ; Lemire, 2 kroki na 4 cyfrach
    shr eax, 8
    and eax, 0x00ff00ff
    imul eax, eax, 100 * 65536 + 1
    shr eax, 16
    test edi, edi
    jnz .neg_ret
    ret
.not4:
    ja .swar8
    cmp edx, 2
    je .len2
    jb .len1
    add r12, 3
    shl r9d, 8                      ; 3 cyfry -> jak 4 z zerem na początku
    imul eax, r9d, 10 * 256 + 1
    shr eax, 8
    and eax, 0x00ff00ff
    imul eax, eax, 100 * 65536 + 1
    shr eax, 16
    test edi, edi
    jnz .neg_ret
    ret
.len2:
    add r12, 2
    imul eax, r9d, 10 * 256 + 1     ; bajt 1 = 10 * d0 + d1
    shr eax, 8
    movzx eax, al
    test edi, edi
    jnz .neg_ret
    ret
.len1:
    inc r12
    movzx eax, r9b
    test edi, edi
    jnz .neg_ret
    ret
.swar8:
    ; 5..7 cyfr — Lemire na 64 bitach (pierwsza cyfra w najniższym bajcie)
    add r12, rdx
    neg edx
    lea ecx, [rdx*8 + 64]           ; 64 - 8 * liczba cyfr
    shl r9, cl
    imul rax, r9, 10 * 256 + 1
    shr rax, 8
    mov rdx, 0x00ff00ff00ff00ff
    and rax, rdx
    imul rax, rax, 100 * 65536 + 1
    shr rax, 16
    mov rdx, 0x0000ffff0000ffff
    and rax, rdx
    mov rdx, (10000 << 32) + 1
    imul rax, rdx
    shr rax, 32
    jmp .apply
.scalar:
    xor eax, eax
    mov r9d, 18             ; 18 cyfr nie przepełni int64 — bez sprawdzania
.digit_fast:
    lea rax, [rax+rax*4]
    lea rax, [rcx+rax*2]
    inc r12
    cmp r12, r13
    jae .apply
    movzx ecx, byte [r12]
    sub ecx, '0'
    cmp ecx, 9
    ja .apply
    dec r9d
    jnz .digit_fast
.digit:
    imul rax, rax, 10
    jo err_big_number
    add rax, rcx
    jo err_big_number
    inc r12
    cmp r12, r13
    jae .apply
    movzx ecx, byte [r12]
    sub ecx, '0'
    cmp ecx, 9
    jbe .digit
.apply:
    test edi, edi
    jz .done
.neg_ret:
    neg rax
    jo err_overflow
.done:
    ret
.not_digit:
    cmp r12, r13
    jae err_incomplete
    cmp cl, '-' - '0'
    je .minus
    cmp cl, '+' - '0'
    je .plus
    cmp cl, '(' - '0'
    je .paren
    jmp err_unexpected
.minus:
    xor edi, 1
    inc r12
    jmp .sign
.plus:
    inc r12
    jmp .sign
.paren:
    cmp rsp, [stack_floor]
    jb err_too_deep
    inc r12
    push rbx                ; stan otaczającego eval_sum i tego czynnika
    push rbp
    push rsi
    push rdi
    call eval_sum           ; kończy z pominiętymi spacjami
    mov rax, rbx
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    cmp byte [r12], ')'
    jne err_rparen
    inc r12
    jmp .apply

EERR err_unexpected, "nieoczekiwany znak w wyrażeniu"
EERR err_incomplete, "niekompletne wyrażenie"
EERR err_rparen,     "brak ')' w wyrażeniu"
EERR err_div_zero,   "dzielenie przez zero"
EERR err_too_deep,   "wyrażenie zbyt głęboko zagnieżdżone"
EERR err_overflow,   "przepełnienie: wynik poza zakresem liczb 64-bitowych"
EERR err_big_number, "liczba za duża (max 9223372036854775807)"
