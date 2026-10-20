; rt_flt.inc — ułamki (double) w środowisku uruchomieniowym; dołączane do rt.asm
;
; Liczba "dynamiczna" (zmienna, która raz trzyma liczbę całkowitą, a raz
; ułamek) to para: rax = wartość (liczba albo bity ułamka), edx = rodzaj
; (1 = liczba całkowita, 2 = ułamek) — ten sam bajt co flaga "ma wartość".

%define FLT_K_MIN -324              ; pierwszy wpis tablicy rt_flt_g (flt_tab.inc)

; rt_flt_fmt(rax = bity ułamka, rdi = bufor, min. 32 B) -> rdi = za zapisem.
; Zapis jak repr() w Pythonie: najkrótszy, który po wczytaniu daje tę samą
; liczbę (algorytm Schubfach, R. Giulietti), notacja wykładnicza dla
; wykładnika < -4 albo >= 16. Zmienia rax, rcx, rdx, rsi, r8-r11.
rt_flt_fmt:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov rbx, rax
    btr rbx, 63                     ; rbx = |x|, CF = znak
    setc cl
    mov rax, 0x7ff0000000000000
    cmp rbx, rax
    ja .nan
    test cl, cl
    jz .pos
    mov byte [rdi], '-'
    inc rdi
.pos:
    cmp rbx, rax
    je .inf
    test rbx, rbx
    jz .zero
    mov r9, rbx
    shr r9, 52                      ; wykładnik z przesunięciem
    mov rax, 0x000fffffffffffff
    and rbx, rax                    ; mantysa bez ukrytej jedynki
    test r9d, r9d
    jz .sub
    mov ecx, 1075
    sub ecx, r9d                    ; mq: x = c / 2^mq
    bts rbx, 52                     ; c
    lea eax, [rcx - 1]
    cmp eax, 51
    ja .gen
    mov rax, rbx                    ; 0 < mq < 53: może to liczba całkowita
    shr rax, cl
    mov rdx, rax
    shl rdx, cl
    cmp rdx, rbx
    jne .gen
    xor ebp, ebp                    ; f = rax, e = 0
    jmp .digits
.gen:
    neg ecx
    movsxd r8, ecx                  ; q = -mq
    jmp .todec
.sub:                               ; liczby podnormalne
    cmp rbx, 3
    jae .sub_gen
    mov eax, 5                      ; dwie najmniejsze: 5e-324, 1e-323
    mov rbp, -324
    cmp rbx, 1
    je .digits
    mov eax, 1
    mov rbp, -323
    jmp .digits
.sub_gen:
    mov r8, -1074
.todec:
    ; x = c * 2^q (rbx = c, r8 = q) -> rax = f, rbp = e: x ~ f * 10^e
    push rdi
    mov r12, rbx
    and r12d, 1                     ; out: c nieparzyste — końce przedziału poza nim
    lea r13, [rbx*4]                ; cb
    lea r10, [r13 - 2]              ; cbl
    mov rax, r8
    mov rcx, 661971961083
    imul rax, rcx
    mov rcx, 1 << 52
    cmp rbx, rcx
    jne .k
    cmp r8, -1074
    je .k
    mov rcx, 274743187321           ; c = 2^52: przedział niesymetryczny
    sub rax, rcx
    lea r10, [r13 - 1]
.k:
    sar rax, 41
    mov rbp, rax                    ; k = floor(log10(...))
    mov rax, rbp
    neg rax
    mov rcx, 913124641741
    imul rax, rcx
    sar rax, 38
    lea rcx, [r8 + rax + 2]         ; h = q + floor(log2(10^-k)) + 2
    lea rax, [rt_flt_g]
    lea rdx, [rbp - FLT_K_MIN]
    shl rdx, 4
    mov r9, [rax + rdx]             ; g1
    mov r11, [rax + rdx + 8]        ; g0
    mov rsi, r13
    shl rsi, cl
    call .rop
    mov r14, rax                    ; vb
    mov rsi, r10
    shl rsi, cl
    call .rop
    mov r10, rax                    ; vbl
    lea rsi, [r13 + 2]
    shl rsi, cl
    call .rop
    mov r13, rax                    ; vbr
    mov rbx, r14
    shr rbx, 2                      ; s
    cmp rbx, 100
    jb .len_same
    ; krótszy zapis: wielokrotność 10 w przedziale
    mov rax, rbx
    mov rdx, 1844674407370955162
    mul rdx                         ; rdx = s / 10
    lea rsi, [rdx + rdx*4]
    add rsi, rsi                    ; sp10
    lea rdi, [rsi + 10]             ; tp10
    lea rax, [r10 + r12]
    lea rdx, [rsi*4]
    cmp rax, rdx
    setbe al                        ; upin
    lea rdx, [rdi*4 + r12]
    cmp rdx, r13
    setbe dl                        ; wpin
    cmp al, dl
    je .len_same
    test al, al
    mov rax, rdi
    cmovnz rax, rsi
    jmp .todec_done
.len_same:
    lea rdi, [rbx + 1]              ; t
    lea rax, [r10 + r12]
    lea rdx, [rbx*4]
    cmp rax, rdx
    setbe al                        ; uin
    lea rdx, [rdi*4 + r12]
    cmp rdx, r13
    setbe dl                        ; win
    cmp al, dl
    je .tie
    test al, al
    mov rax, rdi
    cmovnz rax, rbx
    jmp .todec_done
.tie:                               ; oba w przedziale: bliższy, przy remisie parzysty
    lea rdx, [rbx + rdi]
    add rdx, rdx
    mov rax, r14
    sub rax, rdx
    jl .take_s
    jg .take_t
    test bl, 1
    jz .take_s
.take_t:
    mov rax, rdi
    jmp .todec_done
.take_s:
    mov rax, rbx
.todec_done:
    pop rdi
.digits:
    ; rax = f, rbp = e; bez zer na końcu f
.strip:
    mov rcx, rax
    mov rdx, 0xcccccccccccccccd
    mul rdx
    shr rdx, 3
    lea r8, [rdx + rdx*4]
    add r8, r8
    cmp r8, rcx
    jne .stripped
    mov rax, rdx
    inc rbp
    jmp .strip
.stripped:
    mov rax, rcx
    sub rsp, 32
    lea rsi, [rsp + 32]
    call rt_fmt
    lea r8, [rsp + 32]
    sub r8, rsi                     ; n = liczba cyfr
    add rbp, r8                     ; decpt: x = 0.cyfry * 10^decpt
    cmp rbp, -3
    jl .sci
    cmp rbp, 16
    jg .sci
    test rbp, rbp
    jg .fx_pos
    mov word [rdi], '0.'            ; 0.000cyfry
    add rdi, 2
    mov rcx, rbp
    neg rcx
    mov al, '0'
    rep stosb
    mov rcx, r8
    rep movsb
    jmp .done
.fx_pos:
    cmp rbp, r8
    jl .fx_mid
    mov rcx, r8                     ; cyfry000.0
    rep movsb
    mov rcx, rbp
    sub rcx, r8
    mov al, '0'
    rep stosb
    mov word [rdi], '.0'
    add rdi, 2
    jmp .done
.fx_mid:
    mov rcx, rbp                    ; cyf.ry
    rep movsb
    mov byte [rdi], '.'
    inc rdi
    mov rcx, r8
    sub rcx, rbp
    rep movsb
    jmp .done
.sci:
    movsb                           ; c[.yfry]e±WW
    cmp r8, 1
    je .exp
    mov byte [rdi], '.'
    inc rdi
    lea rcx, [r8 - 1]
    rep movsb
.exp:
    mov byte [rdi], 'e'
    lea rax, [rbp - 1]
    mov byte [rdi + 1], '+'
    test rax, rax
    jns .exp_pos
    mov byte [rdi + 1], '-'
    neg rax
.exp_pos:
    add rdi, 2
    cmp eax, 100
    jb .exp2
    xor edx, edx
    mov ecx, 100
    div ecx
    add al, '0'
    mov [rdi], al
    inc rdi
    mov eax, edx
.exp2:
    lea rcx, [rt_digits2]
    movzx eax, word [rcx + rax*2]
    mov [rdi], ax
    add rdi, 2
.done:
    add rsp, 32
    jmp .ret
.nan:
    mov dword [rdi], 'nan'
    add rdi, 3
    jmp .ret
.inf:
    mov dword [rdi], 'inf'
    add rdi, 3
    jmp .ret
.zero:
    mov dword [rdi], '0.0'
    add rdi, 3
.ret:
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
; .rop(rsi = cp, r9 = g1, r11 = g0) -> rax: zaokrąglone w górę do
; nieparzystej (g * cp) >> 128 (Schubfach: rop); zmienia rdx, r8
.rop:
    mov rax, r11
    mul rsi
    mov r8, rdx                     ; x1
    mov rax, r9
    mul rsi                         ; rax = y0, rdx = y1
    shr rax, 1
    add rax, r8                     ; z
    mov r8, rax
    shr r8, 63
    add rdx, r8                     ; vbp
    btr rax, 63
    mov r8, 0x7fffffffffffffff
    add rax, r8
    shr rax, 63
    or rax, rdx
    ret

; rt_flt_out(rax = bity) — wypisuje ułamek (bez '\n'); rt_flt_out_nl — z '\n'
rt_flt_out:
    xor ecx, ecx
    jmp rt_flt_out_go
rt_flt_out_nl:
    mov ecx, 1
rt_flt_out_go:
    push rcx
    sub rsp, 40
    mov rdi, rsp
    call rt_flt_fmt
    mov rcx, [rsp + 40]
    mov byte [rdi], 10
    add rdi, rcx
    mov rsi, rsp
    mov rdx, rdi
    sub rdx, rsp
    call rt_write
    add rsp, 48
    ret

; rt_num_out(rax, edx = liczba dynamiczna) / rt_num_out_nl — wypisuje ją
rt_num_out:
    cmp edx, 2
    je rt_flt_out
    jmp rt_int
rt_num_out_nl:
    cmp edx, 2
    je rt_flt_out_nl
    jmp rt_int_nl

; rt_flt2text(rax = bity) -> rax, rdx = zapis ułamka (obszar tymczasowy);
; zachowuje rcx, r8 (jak rt_int2text)
rt_flt2text:
    push rcx
    push r8
    sub rsp, 32
    mov rdi, rsp
    call rt_flt_fmt
    mov rcx, rdi
    sub rcx, rsp
    push rcx
    call rt_tmp_alloc
    mov rdi, rax
    lea rsi, [rsp + 8]
    mov rcx, [rsp]
    rep movsb
    pop rdx
    add rsp, 32
    pop r8
    pop rcx
    ret

; rt_num2text(rax, edx = liczba dynamiczna) -> rax, rdx = zapis; zachowuje rcx, r8
rt_num2text:
    cmp edx, 2
    je rt_flt2text
    jmp rt_int2text

; ---------- działania ----------

; rt_fmod(xmm0 = a, xmm1 = b != 0) -> xmm0 = reszta a / b ze znakiem a
; (jak fmod w C; dokładna, x87 fprem); zmienia rax
rt_fmod:
    sub rsp, 16
    movsd [rsp], xmm1
    movsd [rsp + 8], xmm0
    fld qword [rsp]
    fld qword [rsp + 8]
.part:
    fprem
    fnstsw ax
    test ah, 4                      ; C2: redukcja niepełna
    jnz .part
    fstp qword [rsp + 8]
    fstp st0
    movsd xmm0, [rsp + 8]
    add rsp, 16
    ret

; rt_fidiv(xmm0 = a, xmm1 = b != 0) -> xmm0 = iloraz a // b obcięty w stronę
; zera (jak // dla liczb całkowitych), liczony jak w Pythonie:
; (a - fmod(a, b)) / b zaokrąglone do całości; zmienia rax, xmm2, xmm3
rt_fidiv:
    sub rsp, 32
    movsd [rsp + 16], xmm0
    movsd [rsp + 24], xmm1
    call rt_fmod
    movsd xmm2, [rsp + 16]
    subsd xmm2, xmm0
    divsd xmm2, [rsp + 24]
    xorpd xmm3, xmm3
    ucomisd xmm2, xmm3
    jp .round                       ; nan
    jne .round
    movsd xmm0, [rsp + 16]          ; 0 ze znakiem a / b
    divsd xmm0, [rsp + 24]
    movq rax, xmm0
    btr rax, 63
    setc al
    movzx eax, al
    shl rax, 63
    movq xmm0, rax
    add rsp, 32
    ret
.round:
    movsd [rsp], xmm2
    fld qword [rsp]
    frndint
    fstp qword [rsp]
    movsd xmm0, [rsp]
    add rsp, 32
    ret

; rt_idiv_flt(rax = a, rcx = b) -> xmm0 = a / b dokładnie zaokrąglone (jak
; w Pythonie, także dla liczb ponad 2^53); CF = 1, gdy b = 0;
; zmienia rax, rcx, rdx, r8-r11, xmm1
rt_idiv_flt:
    test rcx, rcx
    jz .zero
    mov r8, 1 << 53                 ; obie |liczby| <= 2^53: wystarczy divsd
    lea r9, [rax + r8]
    lea r10, [r8 + r8]
    cmp r9, r10
    ja .exact
    lea r9, [rcx + r8]
    cmp r9, r10
    ja .exact
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, rcx
    divsd xmm0, xmm1
    clc
    ret
.exact:
    mov r11, rax
    xor r11, rcx                    ; bit 63: znak wyniku
    mov r8, rax
    neg r8
    cmovs r8, rax                   ; |a| (bez znaku; |INT64_MIN| = 2^63)
    mov r9, rcx
    neg r9
    cmovs r9, rcx                   ; |b|
    test r8, r8
    jz .signed_zero
    bsr rax, r8
    bsr rcx, r9
    sub eax, ecx                    ; różnica długości
    cmp eax, 55
    jl .scaled
    ; iloraz ma >= 55 bitów: q | (reszta != 0) zaokrągla się jak dokładny
    mov rax, r8
    xor edx, edx
    div r9
    test rdx, rdx
    setnz dl
    movzx edx, dl
    or rax, rdx
    jmp .q_ready
.scaled:
    ; s = 55 - różnica; q = (|a| << s) / |b| ma 55-56 bitów
    mov ecx, 55
    sub ecx, eax                    ; s (1..118)
    push rcx
    xor edx, edx
    mov rax, r8
    cmp ecx, 64
    jb .sh_lo
    sub ecx, 64
    shl rax, cl
    mov rdx, rax
    xor eax, eax
    jmp .sh_done
.sh_lo:
    shld rdx, rax, cl
    shl rax, cl
.sh_done:
    div r9
    test rdx, rdx
    setnz dl
    movzx edx, dl
    or rax, rdx
    cvtsi2sd xmm0, rax
    pop rcx
    mov eax, 1023
    sub eax, ecx
    shl rax, 52                     ; 2^-s
    movq xmm1, rax
    mulsd xmm0, xmm1
    jmp .sign
.q_ready:
    ; (tu tylko gdy różnica >= 55) rax = q z bitem reszty
    test rax, rax
    js .q_big
    cvtsi2sd xmm0, rax
    jmp .sign
.q_big:                             ; q >= 2^63: połowa z zachowanym bitem 0
    mov rdx, rax
    shr rax, 1
    and edx, 1
    or rax, rdx
    cvtsi2sd xmm0, rax
    addsd xmm0, xmm0
.sign:
    test r11, r11
    jns .ok
    movq rax, xmm0
    btc rax, 63
    movq xmm0, rax
.ok:
    clc
    ret
.signed_zero:
    xor eax, eax
    test r11, r11
    jns .z
    bts rax, 63
.z:
    movq xmm0, rax
    clc
    ret
.zero:
    stc
    ret

; rt_darith(edi = OP_*, rax, edx = A, rcx, r8d = B) -> rax, edx = A op B
; dla liczb dynamicznych (+ - * // % /). Obie całkowite: działanie całkowite
; z błędem przepełnienia; inaczej na ułamkach; / zawsze daje ułamek.
; Błąd: CF = 1, ecx = rodzaj dla rt_die (0 przepełnienie, 1 dzielenie przez zero).
; Zmienia rax, rcx, rdx, rsi, r8-r11, xmm0-xmm3.
rt_darith:
    cmp edi, OP_DIV
    je .div
    cmp edx, 1
    jne .flt
    cmp r8d, 1
    jne .flt
    cmp edi, OP_ADD
    je .add
    cmp edi, OP_SUB
    je .sub
    cmp edi, OP_MUL
    je .mul
    test rcx, rcx                   ; // i %
    jz .div0
    cmp rcx, -1
    je .m1
    cqo
    idiv rcx
    cmp edi, OP_MOD
    jne .int
    mov rax, rdx
    jmp .int
.m1:
    cmp edi, OP_MOD
    je .m1_mod
    neg rax
    jo .ovf
    jmp .int
.m1_mod:
    xor eax, eax
    jmp .int
.add:
    add rax, rcx
    jo .ovf
    jmp .int
.sub:
    sub rax, rcx
    jo .ovf
    jmp .int
.mul:
    imul rax, rcx
    jo .ovf
.int:
    mov edx, 1
    clc
    ret
.flt:
    call .to_xmm
    cmp edi, OP_ADD
    je .fadd
    cmp edi, OP_SUB
    je .fsub
    cmp edi, OP_MUL
    je .fmul
    movq rcx, xmm1                  ; // i %: dzielnik 0 (także -0)
    add rcx, rcx
    jz .div0
    cmp edi, OP_MOD
    je .fmod
    call rt_fidiv
    jmp .flt_ret
.fmod:
    call rt_fmod
    jmp .flt_ret
.fadd:
    addsd xmm0, xmm1
    jmp .flt_ret
.fsub:
    subsd xmm0, xmm1
    jmp .flt_ret
.fmul:
    mulsd xmm0, xmm1
.flt_ret:
    movq rax, xmm0
    mov edx, 2
    clc
    ret
.div:
    cmp edx, 1
    jne .fdiv
    cmp r8d, 1
    jne .fdiv
    call rt_idiv_flt
    jc .div0
    jmp .flt_ret
.fdiv:
    call .to_xmm
    movq rcx, xmm1
    add rcx, rcx
    jz .div0
    divsd xmm0, xmm1
    jmp .flt_ret
.ovf:
    xor ecx, ecx
    stc
    ret
.div0:
    mov ecx, 1
    stc
    ret
; A do xmm0, B do xmm1 (liczby całkowite zamienione na ułamki)
.to_xmm:
    movq xmm0, rax
    cmp edx, 2
    je .b
    cvtsi2sd xmm0, rax
.b:
    movq xmm1, rcx
    cmp r8d, 2
    je .ret
    cvtsi2sd xmm1, rcx
.ret:
    ret

; rt_numcmp(edi = OP_EQ..OP_GE, rax, edx = A, rcx, r8d = B) -> eax = 1/0.
; Dokładne także dla liczby całkowitej z ułamkiem (bez zaokrąglenia ponad
; 2^53); nan nie jest równy niczemu. Zmienia rax, rdx, r9, r10, xmm0, xmm1.
rt_numcmp:
    cmp edx, 2
    je .a_flt
    cmp r8d, 2
    je .if
    xor r9d, r9d                    ; obie całkowite
    cmp rax, rcx
    setg r9b
    jge .map
    mov r9d, -1
    jmp .map
.a_flt:
    cmp r8d, 2
    je .ff
    xchg rax, rcx                   ; ułamek z całkowitą: odwrotnie i zmiana znaku
    call .cmp_if
    cmp r9d, 2
    je .map
    neg r9d
    jmp .map
.if:
    call .cmp_if
    jmp .map
.ff:
    movq xmm0, rax
    movq xmm1, rcx
    mov r9d, 2
    ucomisd xmm0, xmm1
    jp .map
    mov r9d, -1
    jb .map
    mov r9d, 1
    ja .map
    xor r9d, r9d
.map:
    ; r9d: -1 mniejsze, 0 równe, 1 większe, 2 nieporównywalne (nan)
    xor eax, eax
    cmp edi, OP_EQ
    je .eq
    cmp edi, OP_NE
    je .ne
    cmp r9d, 2
    je .ret
    cmp edi, OP_LT
    je .lt
    cmp edi, OP_LE
    je .le
    cmp edi, OP_GT
    je .gt
    cmp r9d, 0                      ; >=
    setge al
    ret
.eq:
    test r9d, r9d
    sete al
    ret
.ne:
    test r9d, r9d
    setne al
    ret
.lt:
    cmp r9d, 0
    setl al
    ret
.le:
    cmp r9d, 0
    setle al
    ret
.gt:
    cmp r9d, 0
    setg al
.ret:
    ret
; .cmp_if(rax = liczba całkowita, rcx = bity ułamka) -> r9d
.cmp_if:
    movq xmm1, rcx
    mov r9d, 2
    ucomisd xmm1, xmm1
    jp .ci_ret
    cvtsi2sd xmm0, rax
    mov r9d, -1
    ucomisd xmm0, xmm1
    jb .ci_ret
    mov r9d, 1
    ja .ci_ret
    ; równe po zaokrągleniu: ułamek jest całkowity, porównanie dokładne
    mov r10, 0x43e0000000000000     ; 2^63
    mov r9d, -1
    cmp rcx, r10
    je .ci_ret
    cvttsd2si r10, xmm1
    xor r9d, r9d
    cmp rax, r10
    je .ci_ret
    mov r9d, -1
    jl .ci_ret
    mov r9d, 1
.ci_ret:
    ret
