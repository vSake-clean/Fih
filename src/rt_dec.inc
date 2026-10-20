; rt_dec.inc — zapis dziesiętny <-> double dokładnie, na dużych liczbach
; całkowitych (dołączane do rt.asm; używa go też kompilator dla literałów).
;
; parse_float: literał 12.375 -> double zaokrąglony do najbliższej (remis:
; parzysta). Wartość = D * 10^E (D — cyfry jako liczba). Liczymy
; q = floor(N * 2^s / P) z 55-56 bitami i resztą ("czy coś zostało"), a potem
; zaokrąglamy q do 53 bitów mantysy (albo mniej dla liczb podnormalnych).
; Cyfry ponad 780. nie zmieniają wyniku poza tym, czy są niezerowe: zostają
; zastąpione jedną cyfrą 1 (wartość dokładna double ma najwyżej 767 cyfr).
;
; Duże liczby: dq długość (w słowach), słowa od najmłodszego. Bufory leżą na
; stosie (obszar roboczy, r15 = jego początek), bo środowisko nie ma .bss.

%define LIMBS   160                 ; 10240 bitów: wystarcza na 1100 cyfr i przesunięcie
%define MAXDIG  780
%define BN_SZ   ((LIMBS + 1) * 8)
%define W_N     0                   ; obszar roboczy: liczby N, P, T, Q i cyfry
%define W_P     BN_SZ
%define W_T     (2 * BN_SZ)
%define W_Q     (3 * BN_SZ)
%define W_DIG   (4 * BN_SZ)
%define W_SIZE  ((4 * BN_SZ + MAXDIG + 8 + 15) & ~15)

; bn_set(rdi = liczba, rax = wartość)
bn_set:
    mov qword [rdi], 1
    mov [rdi + 8], rax
    ret

; bn_mul_add(rdi = liczba, rsi = mnożnik, rcx = składnik): A = A * m + c
bn_mul_add:
    push rbx
    mov rbx, [rdi]
    xor r8d, r8d
.loop:
    cmp r8, rbx
    jae .end
    mov rax, [rdi + 8 + r8*8]
    mul rsi
    add rax, rcx
    adc rdx, 0
    mov [rdi + 8 + r8*8], rax
    mov rcx, rdx
    inc r8
    jmp .loop
.end:
    test rcx, rcx
    jz .ret
    mov [rdi + 8 + rbx*8], rcx
    inc qword [rdi]
.ret:
    pop rbx
    ret

; bn_mul_pow10(rdi = liczba, rdx = k >= 0): A = A * 10^k
bn_mul_pow10:
    push r12
    mov r12, rdx
.big:
    cmp r12, 19
    jb .small
    mov rsi, 10000000000000000000
    xor ecx, ecx
    call bn_mul_add
    sub r12, 19
    jmp .big
.small:
    test r12, r12
    jz .ret
    mov rsi, 10
    xor ecx, ecx
    call bn_mul_add
    dec r12
    jmp .small
.ret:
    pop r12
    ret

; bn_shl(rdi = liczba, rcx = bity >= 0): A = A << n
bn_shl:
    push rbx
    mov rbx, rcx
    shr rbx, 6                      ; całe słowa
    and ecx, 63
    mov r8, [rdi]                   ; stara długość
    ; nowe słowo na górze (dla przesunięcia w obrębie słowa)
    mov qword [rdi + 8 + r8*8], 0
    lea r9, [r8]                    ; i = len .. 1: dst[i + w] = src[i] << c | src[i-1] >> (64-c)
.loop:
    test r9, r9
    jz .last
    mov rax, [rdi + 8 + r9*8]
    mov rdx, [rdi + r9*8]           ; src[i - 1]
    shld rax, rdx, cl
    lea r10, [r9 + rbx]
    mov [rdi + 8 + r10*8], rax
    dec r9
    jmp .loop
.last:
    mov rax, [rdi + 8]
    shl rax, cl
    mov [rdi + 8 + rbx*8], rax
    xor r9d, r9d                    ; młodsze słowa: zera
.zero:
    cmp r9, rbx
    jae .len
    mov qword [rdi + 8 + r9*8], 0
    inc r9
    jmp .zero
.len:
    lea rax, [r8 + rbx + 1]
    mov [rdi], rax
    call bn_trim
    pop rbx
    ret

; bn_trim(rdi) — bez zerowych słów na górze (długość co najmniej 1)
bn_trim:
    mov rax, [rdi]
.loop:
    cmp rax, 1
    jbe .done
    cmp qword [rdi + rax*8], 0
    jne .done
    dec rax
    jmp .loop
.done:
    mov [rdi], rax
    ret

; bn_shr1(rdi): A = A >> 1
bn_shr1:
    mov rcx, [rdi]
    xor r8d, r8d
.loop:
    cmp r8, rcx
    jae .done
    mov rax, [rdi + 8 + r8*8]
    lea r9, [r8 + 1]
    xor edx, edx
    cmp r9, rcx
    jae .top
    mov rdx, [rdi + 8 + r9*8]
.top:
    shrd rax, rdx, 1
    mov [rdi + 8 + r8*8], rax
    inc r8
    jmp .loop
.done:
    jmp bn_trim

; bn_bitlen(rdi) -> rax = liczba bitów (0 dla zera)
bn_bitlen:
    mov rcx, [rdi]
    mov rax, [rdi + rcx*8]          ; najstarsze słowo
    test rax, rax
    jz .zero
    bsr rax, rax
    dec rcx
    shl rcx, 6
    lea rax, [rax + rcx + 1]
    ret
.zero:
    xor eax, eax
    ret

; bn_cmp(rdi = A, rsi = B) -> CF = 1, gdy A < B (obie bez zer na górze)
bn_cmp:
    mov rcx, [rdi]
    cmp rcx, [rsi]
    jne .ret                        ; dłuższa jest większa
.loop:
    mov rax, [rdi + rcx*8]
    cmp rax, [rsi + rcx*8]
    jne .ret
    dec rcx
    jnz .loop
    clc                             ; równe
.ret:
    ret

; bn_sub(rdi = A, rsi = B): A = A - B (A >= B)
bn_sub:
    mov rcx, [rdi]
    xor r8d, r8d
    clc
    pushf
.loop:
    cmp r8, rcx
    jae .done
    xor eax, eax
    cmp r8, [rsi]
    jae .b0
    mov rax, [rsi + 8 + r8*8]
.b0:
    popf
    sbb [rdi + 8 + r8*8], rax
    pushf
    inc r8
    jmp .loop
.done:
    popf
    jmp bn_trim

; bn_copy(rdi = cel, rsi = źródło)
bn_copy:
    mov rcx, [rsi]
    inc rcx
    rep movsq
    ret

; parse_float(rdi = cyfry przed kropką, rsi = ich liczba, rdx = cyfry po
; kropce, rcx = ich liczba) -> rax = bity double; CF = 1: liczba za duża
parse_float:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, W_SIZE
    mov r15, rsp
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rbp, rcx
    neg rbp                         ; E: wartość = cyfry * 10^E
    ; cyfry znaczące (bez zer wiodących) do bufora cyfr, najwyżej MAXDIG
    xor ebx, ebx                    ; liczba cyfr w buforze
    xor r8d, r8d                    ; 1 = obcięto niezerową cyfrę
    xor r9d, r9d                    ; liczba obciętych cyfr
    mov rsi, r12
    mov rcx, r13
    call .take
    mov rsi, r14
    mov rcx, rbp
    neg rcx
    call .take
    test rbx, rbx
    jz .zero
    add rbp, r9
    test r8d, r8d
    jz .no_sticky
    mov byte [r15 + W_DIG + rbx], 1 ; obcięte niezerowe cyfry: jedna cyfra 1
    inc rbx
    dec rbp
.no_sticky:
    ; rząd wielkości: wartość w [10^(decpt-1), 10^decpt)
    lea rax, [rbx + rbp]
    cmp rax, 310
    jg .huge
    cmp rax, -330
    jl .zero                        ; < 1e-330: zaokrąglenie do 0
    ; N = cyfry (po 19 naraz)
    lea rdi, [r15 + W_N]
    xor eax, eax
    call bn_set
    lea r12, [r15 + W_DIG]
    mov r13, rbx
.chunk:
    test r13, r13
    jz .chunk_done
    mov r14d, 19
    cmp r13, r14
    cmovb r14, r13
    sub r13, r14
    xor ecx, ecx                    ; wartość kawałka
    mov r10d, 1                     ; 10^długość kawałka
    xor r11d, r11d
.cd:
    imul rcx, rcx, 10
    movzx eax, byte [r12 + r11]
    add rcx, rax
    imul r10, r10, 10
    inc r11
    cmp r11, r14
    jb .cd
    add r12, r14                    ; (10^19 też się mieści: imul daje młodsze 64 bity)
    lea rdi, [r15 + W_N]
    mov rsi, r10
    call bn_mul_add
    jmp .chunk
.chunk_done:
    mov rsi, rbp
    call dec_core
    jmp .ret
.zero:
    xor eax, eax
    clc
    jmp .ret
.huge:
    stc
.ret:
    lea rsp, [rsp + W_SIZE]         ; (lea nie zmienia CF)
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; .take(rsi = cyfry, rcx = liczba) — dopisuje cyfry znaczące do bufora cyfr
; (rbx = ile jest, r8 = obcięto niezerową, r9 = ile obcięto)
.take:
    test rcx, rcx
    jz .take_ret
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    sub eax, '0'
    test rbx, rbx
    jnz .take_sig
    test eax, eax
    jz .take                        ; zero wiodące
.take_sig:
    cmp rbx, MAXDIG
    jae .take_cut
    mov [r15 + W_DIG + rbx], al
    inc rbx
    jmp .take
.take_cut:
    inc r9
    or r8d, eax
    jmp .take
.take_ret:
    ret

; dec_core(r15 = obszar roboczy z N > 0, rsi = E) -> rax = bity double
; najbliższego N * 10^E; CF = 1: za duża. Zmienia rcx, rdx, rsi, rdi, r8-r11.
dec_core:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov rbp, rsi
    lea rdi, [r15 + W_P]
    mov eax, 1
    call bn_set
    test rbp, rbp
    js .neg_e
    lea rdi, [r15 + W_N]
    mov rdx, rbp
    call bn_mul_pow10
    jmp .scaled
.neg_e:
    lea rdi, [r15 + W_P]
    mov rdx, rbp
    neg rdx
    call bn_mul_pow10
.scaled:
    ; s = min(55 - (bity(N) - bity(P)), 1076)
    lea rdi, [r15 + W_N]
    call bn_bitlen
    mov rbx, rax
    lea rdi, [r15 + W_P]
    call bn_bitlen
    sub rbx, rax
    mov eax, 55
    sub rax, rbx
    mov ecx, 1076
    cmp rax, rcx
    cmovg rax, rcx
    mov rbx, rax                    ; rbx = s
    test rbx, rbx
    js .shift_p
    lea rdi, [r15 + W_N]
    mov rcx, rbx
    call bn_shl
    jmp .divide
.shift_p:
    lea rdi, [r15 + W_P]
    mov rcx, rbx
    neg rcx
    call bn_shl
.divide:
    ; T = P << 56; dla i = 56..0: N >= T -> N -= T, bit i ilorazu; T >>= 1
    lea rdi, [r15 + W_T]
    lea rsi, [r15 + W_P]
    call bn_copy
    lea rdi, [r15 + W_T]
    mov ecx, 56
    call bn_shl
    xor r12d, r12d                  ; q
    mov r13d, 56
.div_loop:
    lea rdi, [r15 + W_N]
    lea rsi, [r15 + W_T]
    call bn_cmp
    jc .div_next
    lea rdi, [r15 + W_N]
    lea rsi, [r15 + W_T]
    call bn_sub
    bts r12, r13
.div_next:
    lea rdi, [r15 + W_T]
    call bn_shr1
    dec r13
    jns .div_loop
    ; reszta: N != 0
    xor r14d, r14d
    cmp qword [r15 + W_N], 1
    ja .sticky
    cmp qword [r15 + W_N + 8], 0
    je .round
.sticky:
    mov r14d, 1
.round:
    ; shift = max(bity(q) - 53, s - 1074)
    xor eax, eax
    test r12, r12
    jz .bl0
    bsr rax, r12
    inc eax
.bl0:
    sub rax, 53
    lea rcx, [rbx - 1074]
    cmp rax, rcx
    cmovl rax, rcx
    mov rcx, rax                    ; shift (>= 2)
    mov rax, r12
    shr rax, cl                     ; m
    mov rdx, 1
    shl rdx, cl
    dec rdx
    and rdx, r12                    ; reszta bitów
    mov r8, 1
    dec cl
    shl r8, cl                      ; połowa
    inc cl
    cmp rdx, r8
    jb .no_up
    ja .up
    test r14d, r14d
    jnz .up
    test al, 1
    jz .no_up
.up:
    inc rax
    bt rax, 53
    jnc .no_up
    shr rax, 1
    inc rcx
.no_up:
    ; wartość = m * 2^(shift - s)
    bt rax, 52
    jnc .subnormal
    sub rcx, rbx
    add rcx, 52 + 1023              ; wykładnik z przesunięciem
    cmp rcx, 2047
    jge .huge
    btr rax, 52
    shl rcx, 52
    or rax, rcx
.subnormal:
    clc
    jmp .ret
.huge:
    stc
.ret:
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; bn_divmod(rdi = N, rsi = D > 0, rdx = Q, rcx = T): Q = N / D, N = N mod D
; (dzielenie bit po bicie; T — bufor pomocniczy)
bn_divmod:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rbx, rcx
    mov rdi, r12
    call bn_bitlen
    mov rbp, rax
    mov rdi, r13
    call bn_bitlen
    sub rbp, rax                    ; k = bity(N) - bity(D)
    ; Q = 0 (k / 64 + 1 słów)
    mov rcx, rbp
    sar rcx, 6
    inc rcx
    cmp rcx, 1
    jge .qlen
    mov ecx, 1
.qlen:
    mov [r14], rcx
.qzero:
    mov qword [r14 + rcx*8], 0
    dec rcx
    jnz .qzero
    test rbp, rbp
    js .done
    ; T = D << k; dla i = k..0: N >= T -> N -= T, bit i; T >>= 1
    mov rdi, rbx
    mov rsi, r13
    call bn_copy
    mov rdi, rbx
    mov rcx, rbp
    call bn_shl
.loop:
    mov rdi, r12
    mov rsi, rbx
    call bn_cmp
    jc .next
    mov rdi, r12
    mov rsi, rbx
    call bn_sub
    mov rax, rbp
    shr rax, 6
    mov rcx, rbp
    and ecx, 63
    mov rdx, 1
    shl rdx, cl
    or [r14 + 8 + rax*8], rdx
.next:
    mov rdi, rbx
    call bn_shr1
    dec rbp
    jns .loop
.done:
    mov rdi, r14
    call bn_trim
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
