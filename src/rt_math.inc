; rt_math.inc — funkcje modułu math (dołączane do rt.asm)
;
; Argumenty i wyniki to liczby dynamiczne: rax = wartość (liczba całkowita
; albo bity ułamka), edx = rodzaj (1 całkowita, 2 ułamek); drugi argument
; w rcx, r8d. Błąd: CF = 1, ecx = rodzaj dla rt_die (0 przepełnienie,
; 1 dzielenie przez zero, 3 potrzebna liczba całkowita, 4 argument spoza
; dziedziny, 5 wynik za duży). Funkcje przestępne liczy x87 (64 bity mantysy,
; wynik zaokrąglany do double); sin/cos/tan redukują argument dokładnie
; (Payne-Hanek, bity 2/pi w trig_tab.inc). Zachowują rbx, rbp, r12-r15;
; zmieniają rax, rcx, rdx, rsi, rdi, r8-r11, xmm0-xmm3.
;
; Liczba całkowita jako argument funkcji ułamkowej zamieniana jest najpierw
; na double (jak w Pythonie: math.sqrt(2**53 + 1) == math.sqrt(2**53)).

%define F_INF   0x7ff0000000000000
%define F_ONE   0x3ff0000000000000
%define F_HALF  0x3fe0000000000000

; TO_DBL xmm, wartość, rodzaj — liczba dynamiczna jako double
%macro TO_DBL 3
    cmp %3, 1
    jne %%flt
    cvtsi2sd %1, %2
    jmp %%done
%%flt:
    movq %1, %2
%%done:
%endmacro

; rt_math1(edi = M1_*, rax, edx = x) -> rax, edx
rt_math1:
    push rbx
    push rbp
    sub rsp, 56                     ; [rsp] pomocnicze (x87: 10 B)
    mov ebx, edi
    cmp ebx, M1_ABS
    je .abs
    cmp ebx, M1_FLOOR
    jae .toint
    TO_DBL xmm0, rax, edx
    movq rbp, xmm0                  ; rbp = bity x
    movsd [rsp], xmm0
    ucomisd xmm0, xmm0
    jp .ret_x                       ; nan -> nan
    lea rcx, [.tab]
    movsxd rax, dword [rcx + rbx*4]
    add rax, rcx
    jmp rax
.tab:
    dd .sqrt - .tab, .sin - .tab, .cos - .tab, .tan - .tab
    dd .asin - .tab, .acos - .tab, .atan - .tab, .exp - .tab
    dd .log - .tab, .log2 - .tab, .log10 - .tab

.sqrt:
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jb .e_dom                       ; x < 0 (-0.0 daje -0.0)
    sqrtsd xmm0, xmm0
    movq rax, xmm0
    jmp .ret_flt

.sin:
    call m_trig_arg                 ; st0 = r, eax = ćwiartka
    jc .e_dom
    fsincos                         ; st0 = cos r, st1 = sin r
    test eax, 1
    jnz .sin_c
    fstp st0                        ; sin r
    jmp .sin_s
.sin_c:
    fstp st1                        ; cos r
.sin_s:
    shr eax, 1                      ; ćwiartki 2, 3: minus; x < 0: minus
    mov rcx, rbp
    shr rcx, 63
    xor eax, ecx
    test eax, 1
    jz .ret_x87
    fchs
    jmp .ret_x87

.cos:
    call m_trig_arg
    jc .e_dom
    fsincos
    test eax, 1
    jnz .cos_s
    fstp st1                        ; cos r
    jmp .cos_sign
.cos_s:
    fstp st0                        ; sin r
.cos_sign:
    inc eax                         ; ćwiartki 1, 2: minus
    test eax, 2
    jz .ret_x87
    fchs
    jmp .ret_x87

.tan:
    call m_trig_arg
    jc .e_dom
    fsincos
    test eax, 1
    jnz .tan_odd
    fdivp st1, st0                  ; sin / cos
    jmp .tan_sign
.tan_odd:
    fdivrp st1, st0                 ; cos / sin, potem minus
    fchs
.tan_sign:
    test rbp, rbp
    jns .ret_x87
    fchs
    jmp .ret_x87

.asin:
    call .unit_check
    fld qword [rsp]
    call .sqrt_1mx2                 ; st0 = sqrt((1 - x)(1 + x)), st1 = x
    fpatan                          ; atan(x / sqrt(1 - x^2))
    jmp .ret_x87
.acos:
    call .unit_check
    fld qword [rsp]
    call .sqrt_1mx2
    fxch
    fpatan                          ; atan2(sqrt(1 - x^2), x)
    jmp .ret_x87
.atan:
    fld qword [rsp]
    fld1
    fpatan
    jmp .ret_x87

.exp:
    mov rax, rbp
    btr rax, 63
    mov rcx, F_INF
    cmp rax, rcx
    jne .exp_go
    test rbp, rbp
    jns .ret_x                      ; exp(inf) = inf
    xor eax, eax                    ; exp(-inf) = 0
    jmp .ret_flt
.exp_go:
    mov rcx, 0x4086300000000000     ; x > 710: za duży wynik
    cmp rbp, rcx
    jg .e_rng
    mov rcx, 0x4087500000000000     ; x < -746: 0
    cmp rax, rcx
    jbe .exp_red
    test rbp, rbp
    jns .exp_red
    xor eax, eax
    jmp .ret_flt
.exp_red:
    ; e^x = 2^n * e^r, n = round(x / ln 2), r = x - n * ln 2 (ln 2 w dwóch
    ; częściach: n * hi jest dokładne), e^r = 2^(r * log2 e)
    fld qword [rsp]
    fld st0
    fldl2e
    fmulp st1, st0
    frndint                         ; [n, x]
    fld qword [m_ln2hi]
    fmul st0, st1
    fsubp st2, st0                  ; [n, x - n hi]
    fld tword [m_ln2lo]
    fmul st0, st1
    fsubp st2, st0                  ; [n, r]
    fxch
    fldl2e
    fmulp st1, st0
    f2xm1
    fld1
    faddp st1, st0
    fscale
    fstp st1
    jmp .ret_x87_rng

.log:
    fldln2
    jmp .log_go
.log2:
    fld1
    jmp .log_go
.log10:
    fldlg2
.log_go:
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jbe .e_dom                      ; x <= 0
    call m_logc
    jmp .ret_x87

; floor / ceil / trunc / round: liczba całkowita bez zmian, ułamek -> całkowita
.toint:
    cmp edx, 1
    je .ret                         ; (CF = 0 po cmp równych)
    movq xmm0, rax
    call m_toint
    jc .err
    mov edx, 1
    jmp .ret

.abs:
    cmp edx, 1
    jne .abs_f
    mov rcx, rax
    neg rax
    jo .e_ovf                       ; -2^63
    cmovs rax, rcx
    clc
    jmp .ret
.abs_f:
    btr rax, 63
    clc
    jmp .ret

; |x| > 1: błąd dziedziny (x w [rsp + 8] — wywołane z rt_math1)
.unit_check:
    mov rax, rbp
    btr rax, 63
    mov rcx, F_ONE
    cmp rax, rcx
    ja .uc_bad
    ret
.uc_bad:
    add rsp, 8
    jmp .e_dom
; st0 = x -> st0 = sqrt((1 - x)(1 + x)), st1 = x
.sqrt_1mx2:
    fld1
    fsub st0, st1
    fld1
    fadd st0, st2
    fmulp st1, st0
    fsqrt
    ret

.ret_x87_rng:
    fstp qword [rsp]
    mov rax, [rsp]
    mov rcx, rax
    btr rcx, 63
    mov rdx, F_INF
    cmp rcx, rdx
    je .e_rng                       ; skończony argument, nieskończony wynik
    jmp .ret_flt
.ret_x87:
    fstp qword [rsp]
    mov rax, [rsp]
    jmp .ret_flt
.ret_x:
    mov rax, rbp
.ret_flt:
    mov edx, 2
    clc
.ret:
    lea rsp, [rsp + 56]
    pop rbp
    pop rbx
    ret
.e_ovf:
    xor ecx, ecx
    jmp .err
.e_dom:
    mov ecx, 4
    jmp .err
.e_rng:
    mov ecx, 5
.err:
    fninit                          ; pusty stos x87
    stc
    jmp .ret

; m_trig_arg(rbp = bity x) -> st0 = r, eax = ćwiartka k (|x| = r + k * pi/2
; mod 2pi, |r| <= pi/4); CF = 1 dla nieskończoności
m_trig_arg:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 24
    mov rax, rbp
    btr rax, 63                     ; |x|
    mov rcx, F_INF
    cmp rax, rcx
    jae .inf
    mov rcx, 0x3fe921fb54442d18     ; pi/4
    cmp rax, rcx
    jae .reduce
    mov [rsp], rax
    fld qword [rsp]
    xor eax, eax
    jmp .ok
.reduce:
    ; x = m * 2^E; x * 2/pi mod 4 z okna 192 bitów 2/pi od bitu j0 = E + 62
    mov rdx, rax
    shr rdx, 52
    mov r8, (1 << 52) - 1
    and r8, rax
    bts r8, 52                      ; m
    lea rcx, [rdx - 1075 + 62]      ; j0
    mov r9, rcx
    shr r9, 6
    and ecx, 63
    lea r10, [rt_2opi]
    lea r10, [r10 + r9*8]
    mov r11, [r10]
    mov rax, [r10 + 8]
    shld r11, rax, cl               ; w0 (najstarsze)
    mov r12, [r10 + 8]
    mov rax, [r10 + 16]
    shld r12, rax, cl               ; w1
    mov r13, [r10 + 16]
    mov rax, [r10 + 24]
    shld r13, rax, cl               ; w2
    ; P = m * (w0:w1:w2): R0 = lo(m w2), R1, R2 (bity 128..191)
    mov rax, r8
    mul r13
    mov r14, rax                    ; R0
    mov r13, rdx                    ; hi(m w2)
    mov rax, r8
    mul r12
    add r13, rax                    ; R1
    adc rdx, 0
    mov r12, rdx                    ; hi(m w1) + przeniesienie
    mov rax, r8
    imul rax, r11                   ; lo(m w0)
    add r12, rax                    ; R2 (wyższe bity to wielokrotności 4)
    ; ćwiartka = bity 190-191 (R2 >> 62); ułamek = P << 2 (192 bity)
    mov rbx, r12
    shr rbx, 62
    shld r12, r13, 2
    shld r13, r14, 2
    shl r14, 2
    xor r9d, r9d                    ; znak r
    test r12, r12
    jns .pos
    not r12                         ; ułamek >= 1/2: r = ułamek - 1, k + 1
    not r13
    neg r14
    cmc
    adc r13, 0
    adc r12, 0
    inc ebx
    mov r9d, 0x8000
.pos:
    ; normalizacja: pierwszy bit ułamka na górze 64 bitów mantysy
    mov ecx, 16382                  ; wykładnik x87 dla ułamka w [1/2, 1)
    test r12, r12
    jnz .norm
    mov r12, r13
    mov r13, r14
    xor r14d, r14d
    sub ecx, 64
    test r12, r12
    jnz .norm
    mov r12, r13
    xor r13d, r13d
    sub ecx, 64
    test r12, r12
    jnz .norm
    fldz                            ; (nie zdarza się dla double)
    jmp .quad
.norm:
    bsr rax, r12
    xor eax, 63                     ; zera wiodące
    sub ecx, eax
    push rcx
    mov ecx, eax
    shld r12, r13, cl
    pop rcx
    or ecx, r9d
    mov [rsp], r12
    mov [rsp + 8], cx
    fld tword [rsp]
    fld tword [rt_pio2]
    fmulp st1, st0                  ; r = ułamek * pi/2
.quad:
    mov eax, ebx
    and eax, 3
.ok:
    clc
.ret:
    lea rsp, [rsp + 24]
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.inf:
    stc
    jmp .ret

m_ln2hi: dq 0x3fe62e42fefa39ef     ; ln 2 zaokrąglone do double
m_ln2lo: dq 0xd5e4f1d9cc01f97b      ; ln 2 - m_ln2hi (80 bitów)
         dw 0x3fc7

; m_logc(st0 = c, xmm0 = x > 0) -> st0 = c * log2(x); blisko 1 przez
; fyl2xp1 na dokładnym x - 1 (bez utraty cyfr)
m_logc:
    sub rsp, 8
    mov rax, F_ONE
    movq xmm1, rax
    movapd xmm2, xmm0
    subsd xmm2, xmm1
    movq rax, xmm2
    btr rax, 63
    mov rcx, 0x3fd28f5c28f5c28f     ; |x - 1| < 0,29 (warunek fyl2xp1)
    cmp rax, rcx
    jae .plain
    movsd [rsp], xmm2
    fld qword [rsp]
    fyl2xp1
    add rsp, 8
    ret
.plain:
    movsd [rsp], xmm0
    fld qword [rsp]
    fyl2x
    add rsp, 8
    ret

; m_exp2: st0 = t -> st0 = 2^t
m_exp2:
    fld st0
    frndint
    fsub st1, st0                   ; st0 = n, st1 = t - n
    fxch
    f2xm1
    fld1
    faddp st1, st0
    fscale
    fstp st1
    ret

; m_toint(xmm0 = x, ebx = M1_FLOOR..M1_ROUND) -> rax; CF, ecx = błąd
m_toint:
    ucomisd xmm0, xmm0
    jp .nan
    movq rax, xmm0
    mov rcx, 0xc3e0000000000000     ; -2^63 mieści się
    cmp rax, rcx
    je .min
    mov rcx, rax
    btr rcx, 63
    mov rdx, 0x43e0000000000000     ; |x| >= 2^63 (też nieskończoność)
    cmp rcx, rdx
    jae .ovf
    cvttsd2si rax, xmm0             ; t = obcięte
    cvtsi2sd xmm1, rax
    cmp ebx, M1_TRUNC
    je .ok
    cmp ebx, M1_FLOOR
    jne .ceil
    ucomisd xmm0, xmm1
    jae .ok
    dec rax
    jmp .ok
.ceil:
    cmp ebx, M1_CEIL
    jne .round
    ucomisd xmm0, xmm1
    jbe .ok
    inc rax
    jmp .ok
.round:
    subsd xmm0, xmm1                ; d = x - t (dokładnie)
    movq rcx, xmm0
    mov rdx, rcx
    btr rdx, 63
    mov rsi, F_HALF
    cmp rdx, rsi
    jb .ok
    ja .away
    test al, 1                      ; dokładnie pół: do parzystej
    jz .ok
.away:
    test rcx, rcx
    js .down
    inc rax
    jmp .ok
.down:
    dec rax
.ok:
    clc
    ret
.min:
    mov rax, 1 << 63
    clc
    ret
.nan:
    mov ecx, 4
    stc
    ret
.ovf:
    xor ecx, ecx
    stc
    ret

; rt_math2(edi = M2_*, rax, edx = a, rcx, r8d = b) -> rax, edx
rt_math2:
    push rbx
    push rbp
    push r12
    push r13
    sub rsp, 56
    mov ebx, edi
    mov r12, rax                    ; a
    mov ebp, edx
    mov r13, rcx                    ; b
    mov [rsp + 40], r8d
    lea rsi, [.tab]
    movsxd rdi, dword [rsi + rbx*4]
    add rdi, rsi
    jmp rdi
.tab:
    dd .atan2 - .tab, .hypot - .tab, .pow - .tab, .log - .tab
    dd .round - .tab, .min - .tab, .max - .tab, .randint - .tab

.min:
    mov edi, OP_LT                  ; b < a -> b
    jmp .minmax
.max:
    mov edi, OP_GT                  ; b > a -> b
.minmax:
    mov rax, r13
    mov edx, r8d
    mov rcx, r12
    mov r8d, ebp
    call rt_numcmp
    test eax, eax
    jz .ret_a
    mov rax, r13
    mov edx, [rsp + 40]
    jmp .ok
.ret_a:
    mov rax, r12
    mov edx, ebp
    jmp .ok

.atan2:
    call .dbl2
    fld qword [rsp]                 ; y
    fld qword [rsp + 8]             ; x
    fpatan
    jmp .ret_x87

.hypot:
    call .dbl2
    mov rax, [rsp]
    mov rcx, [rsp + 8]
    btr rax, 63
    btr rcx, 63
    mov rdx, F_INF
    cmp rax, rdx
    je .inf
    cmp rcx, rdx
    je .inf
    cmp rax, rdx
    ja .nan_a
    cmp rcx, rdx
    ja .nan_b
    fld qword [rsp]
    fmul st0, st0
    fld qword [rsp + 8]
    fmul st0, st0
    faddp st1, st0
    fsqrt
    jmp .ret_x87_rng
.inf:
    mov rax, F_INF
    jmp .ret_flt
.nan_a:
    mov rax, [rsp]
    jmp .ret_flt
.nan_b:
    mov rax, [rsp + 8]
    jmp .ret_flt

.log:
    ; log(x, podstawa) = ln x / ln podstawa (każdy zaokrąglony do double, jak w Pythonie)
    call .dbl2
    movsd xmm0, [rsp]
    call .ln
    jc .err
    movsd [rsp + 16], xmm0
    movsd xmm0, [rsp + 8]
    call .ln
    jc .err
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jne .log_div
    jp .log_div
    mov ecx, 1                      ; ln podstawa = 0 (podstawa 1): dzielenie przez zero
    jmp .err
.log_div:
    movsd xmm1, [rsp + 16]
    divsd xmm1, xmm0
    movq rax, xmm1
    jmp .ret_flt
; .ln(xmm0) -> xmm0 = ln x; CF, ecx = 4 dla x <= 0
.ln:
    ucomisd xmm0, xmm0
    jp .ln_ok                       ; nan
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jbe .ln_bad
    fldln2
    call m_logc
    fstp qword [rsp + 32]           ; ([rsp + 24] wywołującego)
    movsd xmm0, [rsp + 32]
.ln_ok:
    clc
    ret
.ln_bad:
    mov ecx, 4
    stc
    ret

.pow:
    cmp ebp, 1
    jne .pow_f
    cmp dword [rsp + 40], 1
    jne .pow_f
    test r13, r13
    js .pow_ineg
    ; liczba całkowita ^ liczba całkowita >= 0: dokładnie, z przepełnieniem
    mov r9, r12
    mov r10, r13
    mov eax, 1
.ip_loop:
    test r10, 1
    jz .ip_sq
    imul rax, r9
    jo .e_ovf
.ip_sq:
    shr r10, 1
    jz .ip_done
    imul r9, r9
    jo .e_ovf                       ; (|podstawa| >= 2 i zostały bity: wynik też za duży)
    jmp .ip_loop
.ip_done:
    mov edx, 1
    jmp .ok
.pow_ineg:
    test r12, r12
    jnz .pow_f
    mov ecx, 1                      ; 0 ^ ujemna
    jmp .err
.pow_f:
    call .dbl2
    mov rax, [rsp]                  ; x
    mov rcx, [rsp + 8]              ; y
    mov rdx, rcx
    add rdx, rdx
    jz .one                         ; y = +-0
    mov rdx, F_ONE
    cmp rax, rdx
    je .one                         ; x = 1
    mov rdx, rax
    btr rdx, 63                     ; |x|
    mov rsi, rcx
    btr rsi, 63                     ; |y|
    mov r9, F_INF
    cmp rdx, r9
    ja .ret_x                       ; x nan
    cmp rsi, r9
    ja .ret_y                       ; y nan
    je .y_inf
    call .yint                      ; r10d: 0 nie całkowita, 1 parzysta, 2 nieparzysta
    cmp rdx, r9
    je .x_inf
    test rdx, rdx
    jz .x_zero
    xor r11d, r11d                  ; 1 = wynik ujemny
    test rax, rax
    jns .p_go
    test r10d, r10d
    jz .e_dom                       ; ujemna podstawa, wykładnik nie całkowity
    cmp r10d, 2
    sete r11b
.p_go:
    mov [rsp + 16], rdx             ; |x|
    mov rcx, 0x4050000000000000     ; |y| <= 64 i całkowity: mnożenia x87
    cmp rsi, rcx
    ja .p_log
    test r10d, r10d
    jz .p_log
    movq xmm1, rsi
    cvttsd2si r9, xmm1              ; n = |y|
    fld1
    fld qword [rsp + 16]
.p_loop:
    test r9, 1
    jz .p_sq
    fmul st1, st0
.p_sq:
    shr r9, 1
    jz .p_done
    fmul st0, st0
    jmp .p_loop
.p_done:
    fstp st0
    mov rcx, [rsp + 8]              ; y < 0: odwrotność
    test rcx, rcx
    jns .p_store
    fld1
    fdivrp st1, st0                 ; 1 / x^n
    jmp .p_store
.p_log:
    fld qword [rsp + 8]
    fld qword [rsp + 16]
    fyl2x                           ; t = y * log2|x|
    call m_exp2
.p_store:
    fstp qword [rsp + 16]
    mov rax, [rsp + 16]
    mov rcx, rax
    btr rcx, 63
    mov rdx, F_INF
    cmp rcx, rdx
    je .e_rng
    test r11d, r11d
    jz .ret_flt
    bts rax, 63
    jmp .ret_flt
.y_inf:
    ; |x| = 1: 1; (|x| < 1) xor (y > 0): inf; inaczej 0
    mov r9, F_ONE
    cmp rdx, r9
    je .one
    setb dl                         ; |x| < 1
    test rcx, rcx
    setns cl                        ; y > 0
    xor dl, cl
    jz .zero
    jmp .inf
.x_inf:
    ; x = +inf: y > 0 -> inf, y < 0 -> 0; x = -inf: znak dla nieparzystego y
    xor r11d, r11d
    test rax, rax
    jns .xi_go
    cmp r10d, 2
    sete r11b
.xi_go:
    mov rax, F_INF
    test rcx, rcx
    jns .xi_sign
    xor eax, eax
.xi_sign:
    test r11d, r11d
    jz .ret_flt
    bts rax, 63
    jmp .ret_flt
.x_zero:
    test rcx, rcx
    js .e_dom                       ; 0 ^ ujemna (jak math.pow w Pythonie)
    cmp r10d, 2
    je .ret_flt                     ; +-0 ^ nieparzysta = +-0 (rax = x)
.zero:
    xor eax, eax
    jmp .ret_flt
.one:
    mov rax, F_ONE
    jmp .ret_flt
.ret_x:
    mov rax, [rsp]
    jmp .ret_flt
.ret_y:
    mov rax, [rsp + 8]
    jmp .ret_flt
; .yint(rsi = |y| skończony, niezerowy) -> r10d (zachowuje rax, rcx, rdx, r9)
.yint:
    xor r10d, r10d
    mov r8, rsi
    shr r8, 52                      ; wykładnik
    cmp r8, 1023
    jb .yi_ret                      ; |y| < 1
    mov r10d, 1
    cmp r8, 1075
    jae .yi_ret                     ; |y| >= 2^52: całkowita, parzysta (2^52: też)
    push rcx
    mov rcx, 1075
    sub rcx, r8                     ; bity ułamka
    mov r8, (1 << 52) - 1
    and r8, rsi
    bts r8, 52
    mov r11, 1
    shl r11, cl
    dec r11
    test r8, r11
    jnz .yi_frac
    shr r8, cl
    and r8d, 1
    lea r10d, [r8 + 1]
    pop rcx
    ret
.yi_frac:
    xor r10d, r10d
    pop rcx
.yi_ret:
    ret

.round:
    ; round(x, n): n całkowita; x całkowita -> całkowita, ułamek -> ułamek
    cmp dword [rsp + 40], 1
    jne .e_int
    cmp ebp, 1
    jne .round_f
    test r13, r13
    jns .ret_a
    cmp r13, -19
    jl .zero_i                      ; |x| < 10^19 / 2
    jg .ri_go
    mov rax, r12                    ; 10^19: |x| <= 5 * 10^18 -> 0, inaczej za duża
    cqo
    xor rax, rdx
    sub rax, rdx
    mov rcx, 5000000000000000000
    cmp rax, rcx
    ja .e_ovf
.zero_i:
    xor eax, eax
    mov edx, 1
    jmp .ok
.ri_go:
    mov rcx, r13
    neg rcx
    mov r9d, 1
.ri_pow:
    imul r9, r9, 10
    loop .ri_pow                    ; r9 = 10^k
    mov rax, r12
    cqo
    idiv r9                         ; rax = q, rdx = reszta (znak x)
    mov rcx, rdx
    sar rcx, 63
    xor rdx, rcx
    sub rdx, rcx                    ; |reszta|
    add rdx, rdx
    cmp rdx, r9
    jb .ri_mul
    ja .ri_away
    test al, 1
    jz .ri_mul
.ri_away:
    test r12, r12
    js .ri_neg
    inc rax
    jmp .ri_mul
.ri_neg:
    dec rax
.ri_mul:
    imul rax, r9
    jo .e_ovf
    mov edx, 1
    jmp .ok
.round_f:
    mov rax, r12
    mov rcx, r13
    call m_round_flt
    jc .err
    jmp .ret_flt

.randint:
    ; random(a, b): liczba całkowita z [a, b] (każda tak samo prawdopodobna)
    cmp ebp, 1
    jne .e_int
    cmp dword [rsp + 40], 1
    jne .e_int
    cmp r12, r13
    jg .e_dom
    mov rbx, r13
    sub rbx, r12
    inc rbx                         ; liczba możliwości (0 = 2^64)
    call rt_rng_next
    test rbx, rbx
    jz .ri_full
    mul rbx                         ; Lemire: wynik = hi(x * n), odrzucenia rzadkie
    cmp rax, rbx
    jae .ri_take
    mov [rsp + 24], rax
    mov [rsp + 32], rdx
    mov rax, rbx
    neg rax
    xor edx, edx
    div rbx
    mov [rsp + 16], rdx             ; próg = 2^64 mod n
    mov rax, [rsp + 24]
    mov rdx, [rsp + 32]
.ri_check:
    cmp rax, [rsp + 16]
    jae .ri_take
    call rt_rng_next
    mul rbx
    jmp .ri_check
.ri_take:
    lea rax, [r12 + rdx]
    mov edx, 1
    jmp .ok
.ri_full:
    mov edx, 1
    jmp .ok

; a, b jako double do [rsp + 8] i [rsp + 16] (dla wywołującego: [rsp], [rsp + 8])
.dbl2:
    TO_DBL xmm0, r12, ebp
    movsd [rsp + 8], xmm0
    mov r8d, [rsp + 48]
    TO_DBL xmm1, r13, r8d
    movsd [rsp + 16], xmm1
    ret

.ret_x87_rng:
    fstp qword [rsp]
    mov rax, [rsp]
    mov rcx, rax
    btr rcx, 63
    mov rdx, F_INF
    cmp rcx, rdx
    je .e_rng
    jmp .ret_flt
.ret_x87:
    fstp qword [rsp]
    mov rax, [rsp]
.ret_flt:
    mov edx, 2
.ok:
    clc
.ret:
    lea rsp, [rsp + 56]
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.e_ovf:
    xor ecx, ecx
    jmp .err
.e_int:
    mov ecx, 3
    jmp .err
.e_dom:
    mov ecx, 4
    jmp .err
.e_rng:
    mov ecx, 5
.err:
    fninit
    stc
    jmp .ret

; m_round_flt(rax = bity x, rcx = n) -> rax = bity round(x, n); CF, ecx = 5
; Dokładnie jak Python: Q = x * 10^n zaokrąglone do całkowitej (remis: do
; parzystej) na dużych liczbach, wynik = double najbliższy Q * 10^-n.
m_round_flt:
    mov rdx, rax
    btr rdx, 63
    jz .same                        ; +-0
    mov r9, F_INF
    cmp rdx, r9
    jae .same                       ; inf, nan
    cmp rcx, 323
    jg .same
    cmp rcx, -308
    jl .zero
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, W_SIZE
    mov r15, rsp
    mov r12, rax
    mov r13, rcx
    mov rbx, rdx
    shr rbx, 52                     ; wykładnik
    mov r14, (1 << 52) - 1
    and r14, rdx
    test rbx, rbx
    jz .den
    bts r14, 52                     ; m
    sub rbx, 1075                   ; E: x = m * 2^E
    jmp .me
.den:
    mov rbx, -1074
.me:
    test r13, r13
    js .go
    lea rax, [rbx + r13]
    test rax, rax
    jns .unchanged                  ; x * 10^n jest całkowite
.go:
    ; licznik m * 10^max(n, 0) * 2^max(E, 0), mianownik 10^max(-n, 0) * 2^max(-E, 0)
    lea rdi, [r15 + W_N]
    mov rax, r14
    call bn_set
    test r13, r13
    jle .n1
    lea rdi, [r15 + W_N]
    mov rdx, r13
    call bn_mul_pow10
.n1:
    test rbx, rbx
    jle .n2
    lea rdi, [r15 + W_N]
    mov rcx, rbx
    call bn_shl
.n2:
    lea rdi, [r15 + W_P]
    mov eax, 1
    call bn_set
    test r13, r13
    jns .d1
    lea rdi, [r15 + W_P]
    mov rdx, r13
    neg rdx
    call bn_mul_pow10
.d1:
    test rbx, rbx
    jns .d2
    lea rdi, [r15 + W_P]
    mov rcx, rbx
    neg rcx
    call bn_shl
.d2:
    lea rdi, [r15 + W_N]
    lea rsi, [r15 + W_P]
    lea rdx, [r15 + W_Q]
    lea rcx, [r15 + W_T]
    call bn_divmod
    ; 2 * reszta w porównaniu z mianownikiem
    lea rdi, [r15 + W_N]
    mov ecx, 1
    call bn_shl
    lea rdi, [r15 + W_N]
    lea rsi, [r15 + W_P]
    call bn_cmp
    jc .no_up
    jnz .up
    test byte [r15 + W_Q + 8], 1
    jz .no_up
.up:
    lea rdi, [r15 + W_Q]
    mov esi, 1
    mov ecx, 1
    call bn_mul_add
.no_up:
    cmp qword [r15 + W_Q], 1
    ja .nz
    cmp qword [r15 + W_Q + 8], 0
    je .q_zero
.nz:
    lea rdi, [r15 + W_N]
    lea rsi, [r15 + W_Q]
    call bn_copy
    mov rsi, r13
    neg rsi
    call dec_core
    jc .big
    bt r12, 63
    jnc .done
    bts rax, 63
    jmp .done
.q_zero:
    mov rax, r12
    and rax, [.sign]                ; +-0 ze znakiem x
    jmp .done
.unchanged:
    mov rax, r12
.done:
    clc
.out:
    lea rsp, [rsp + W_SIZE]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.big:
    mov ecx, 5
    stc
    jmp .out
.same:
    clc
    ret
.zero:
    btr rax, 63
    setc dl
    xor eax, eax
    test dl, dl
    jz .same
    bts rax, 63
    clc
    ret
.sign: dq 1 << 63

; rt_random() -> rax = bity ułamka z [0, 1), edx = 2
rt_random:
    call rt_rng_next
    shr rax, 11
    cvtsi2sd xmm0, rax
    mov rax, 0x3ca0000000000000     ; 2^-53
    movq xmm1, rax
    mulsd xmm0, xmm1
    movq rax, xmm0
    mov edx, 2
    ret

; rt_rng_next -> rax = 64 losowe bity (xoshiro256**; ziarno z getrandom przy
; pierwszym użyciu); zmienia rcx, rdx, rsi, rdi, r8, r9, r11
rt_rng_next:
    mov rax, [r15 + D_RNG]
    or rax, [r15 + D_RNG + 8]
    or rax, [r15 + D_RNG + 16]
    or rax, [r15 + D_RNG + 24]
    jnz .gen
    mov eax, SYS_GETRANDOM
    lea rdi, [r15 + D_RNG]
    mov esi, 32
    xor edx, edx
    syscall
    cmp rax, 32
    je .seeded
    rdtsc                           ; brak getrandom: splitmix64 z licznika czasu
    shl rdx, 32
    or rax, rdx
    mov rcx, 4
    lea rdi, [r15 + D_RNG]
.sm:
    mov rsi, 0x9e3779b97f4a7c15
    add rax, rsi
    mov rdx, rax
    mov rsi, rdx
    shr rsi, 30
    xor rdx, rsi
    mov rsi, 0xbf58476d1ce4e5b9
    imul rdx, rsi
    mov rsi, rdx
    shr rsi, 27
    xor rdx, rsi
    mov rsi, 0x94d049bb133111eb
    imul rdx, rsi
    mov rsi, rdx
    shr rsi, 31
    xor rdx, rsi
    mov [rdi], rdx
    add rdi, 8
    loop .sm
.seeded:
    or qword [r15 + D_RNG], 1       ; stan nie może być samymi zerami
.gen:
    mov r8, [r15 + D_RNG + 8]       ; s1
    lea rax, [r8 + r8*4]
    rol rax, 7
    lea rax, [rax + rax*8]          ; wynik = rotl(s1 * 5, 7) * 9
    mov r9, r8
    shl r9, 17                      ; t
    mov rcx, [r15 + D_RNG]          ; s0
    mov rdx, [r15 + D_RNG + 16]     ; s2
    mov rsi, [r15 + D_RNG + 24]     ; s3
    xor rdx, rcx
    xor rsi, r8
    xor r8, rdx
    xor rcx, rsi
    xor rdx, r9
    rol rsi, 45
    mov [r15 + D_RNG], rcx
    mov [r15 + D_RNG + 8], r8
    mov [r15 + D_RNG + 16], rdx
    mov [r15 + D_RNG + 24], rsi
    ret
