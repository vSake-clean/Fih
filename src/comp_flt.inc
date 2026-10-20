; comp_flt.inc — generator kodu dla ułamków i liczb dynamicznych (dołączany
; do comp.asm)
;
; Rodzaje wyrażeń liczbowych: całkowite (K_CONST, K_VAR, K_REG), ułamki
; (K_FCONST — bity w wartości, K_FVAR, K_FREG — w xmm0) i dynamiczne
; (K_DVAR, K_DREG — rax = wartość, edx = 1 całkowita / 2 ułamek). Rodzaj
; zmiennej liczbowej ustala wnioskowanie (comp_compile): zmienna, do której
; trafiają raz liczby całkowite, a raz ułamki, jest dynamiczna.
; Działania na ułamkach: SSE2 w kodzie; na liczbach dynamicznych i tam, gdzie
; trzeba dokładności (porównanie liczby całkowitej z ułamkiem, a / b dla
; liczb całkowitych) — funkcje środowiska (rt_flt.inc). Stałe po obu stronach
; są liczone podczas kompilacji tymi samymi funkcjami środowiska.

; VAR_DISP cel, numer — przesunięcie wartości zmiennej w obszarze danych
%macro VAR_DISP 2
    mov %1, %2
    shl %1, 4
    add %1, D_VARS
%endmacro

; emit_b(dil = bajt) — dopisuje jeden bajt kodu; zmienia rax
emit_b:
    mov eax, 1
    call code_need
    mov [rax], dil
    ret

; ncls(eax = rodzaj liczby) -> ecx: 1 całkowita, 2 ułamek, 3 dynamiczna
ncls:
    mov ecx, 1
    cmp eax, K_REG
    jbe .ret
    mov ecx, 2
    cmp eax, K_FREG
    jbe .ret
    mov ecx, 3
.ret:
    ret

; fconst(rax = bity) -> esi = przesunięcie nowej stałej 8 B; zmienia rax
fconst:
    push rcx
    mov rcx, rax
    mov esi, [const_buf + 8]
    mov eax, 8
    call const_need
    mov [rax], rcx
    pop rcx
    ret

; emit_dyn(edi = rodzaj liczby, rsi = wartość) — kod: wartość do rax, rodzaj
; do edx; zachowuje rejestry kompilatora poza rax
emit_dyn:
    push rcx
    cmp edi, K_REG
    jbe .int
    cmp edi, K_FCONST
    je .fconst
    cmp edi, K_FVAR
    je .fvar
    cmp edi, K_FREG
    je .freg
    cmp edi, K_DVAR
    jne .ret                        ; K_DREG: już w rax, edx
    EMIT 0x49, 0x8b, 0x87           ; mov rax, [r15 + disp32]
    VAR_DISP ecx, esi
    EMITD ecx
    EMIT 0x41, 0x0f, 0xb6, 0x97     ; movzx edx, byte [r15 + disp32] (rodzaj)
    add ecx, 8
    EMITD ecx
    jmp .ret
.int:
    call materialize
    EMIT 0xba, 1, 0, 0, 0           ; mov edx, 1
    jmp .ret
.fconst:
    EMIT 0x48, 0xb8                 ; mov rax, imm64
    EMITQ rsi
    jmp .flt
.fvar:
    EMIT 0x49, 0x8b, 0x87
    VAR_DISP ecx, esi
    EMITD ecx
    jmp .flt
.freg:
    EMIT 0x66, 0x48, 0x0f, 0x7e, 0xc0   ; movq rax, xmm0
.flt:
    EMIT 0xba, 2, 0, 0, 0           ; mov edx, 2
.ret:
    pop rcx
    ret

; emit_dyn_rcx(edi = rodzaj w pamięci albo stała, rsi = wartość) — kod:
; wartość do rcx, rodzaj do r8d
emit_dyn_rcx:
    push rcx
    cmp edi, K_REG
    jb .int
    cmp edi, K_FCONST
    je .fconst
    cmp edi, K_FVAR
    je .fvar
    EMIT 0x49, 0x8b, 0x8f           ; K_DVAR: mov rcx, [r15 + disp32]
    VAR_DISP ecx, esi
    EMITD ecx
    EMIT 0x45, 0x0f, 0xb6, 0x87     ; movzx r8d, byte [r15 + disp32]
    add ecx, 8
    EMITD ecx
    jmp .ret
.int:
    call load_rcx
    EMIT 0x41, 0xb8, 1, 0, 0, 0     ; mov r8d, 1
    jmp .ret
.fconst:
    EMIT 0x48, 0xb9                 ; mov rcx, imm64
    EMITQ rsi
    jmp .flt
.fvar:
    EMIT 0x49, 0x8b, 0x8f
    VAR_DISP ecx, esi
    EMITD ecx
.flt:
    EMIT 0x41, 0xb8, 2, 0, 0, 0     ; mov r8d, 2
.ret:
    pop rcx
    ret

; emit_xload(edi = rodzaj liczby, rsi = wartość, r10d = 0/1) — kod: wartość
; jako ułamek do xmm0 albo xmm1 (liczba całkowita zamieniana: cvtsi2sd)
emit_xload:
    push rbx
    push rbp
    push rcx
    mov ebx, edi
    mov rbp, rsi
    mov ecx, r10d
    shl ecx, 3                      ; numer xmm w polu reg bajtu ModRM
    cmp ebx, K_CONST
    je .iconst
    cmp ebx, K_VAR
    je .ivar
    cmp ebx, K_REG
    je .ireg
    cmp ebx, K_FCONST
    je .fconst
    cmp ebx, K_FVAR
    je .fvar
    cmp ebx, K_FREG
    je .freg
    cmp ebx, K_DVAR
    jne .dreg
    mov edi, ebx
    mov rsi, rbp
    call emit_dyn
.dreg:
    ; cmp edx, 2 / je ułamek / cvtsi2sd xmmN, rax / jmp dalej / movq xmmN, rax
    EMIT 0x83, 0xfa, 0x02, 0x74, 0x07, 0xf2, 0x48, 0x0f, 0x2a
    lea edi, [rcx + 0xc0]
    call emit_b
    EMIT 0xeb, 0x05, 0x66, 0x48, 0x0f, 0x6e
    lea edi, [rcx + 0xc0]
    call emit_b
    jmp .ret
.iconst:
    cvtsi2sd xmm0, rbp
    movq rax, xmm0
    jmp .const
.fconst:
    mov rax, rbp
.const:
    test rax, rax
    jnz .cmem
    EMIT 0x0f, 0x57                 ; +0.0: xorps xmmN, xmmN
    lea edi, [rcx + 0xc0]
    shr ecx, 3
    add edi, ecx
    call emit_b
    jmp .ret
.cmem:
    call fconst
    EMIT 0xf2, 0x0f, 0x10           ; movsd xmmN, [rip + stała]
    lea edi, [rcx + 0x05]
    call emit_b
    mov edi, S_CONST
    call emit_rel
    jmp .ret
.ivar:
    EMIT 0xf2, 0x49, 0x0f, 0x2a     ; cvtsi2sd xmmN, qword [r15 + disp32]
    jmp .mem
.fvar:
    EMIT 0xf2, 0x41, 0x0f, 0x10     ; movsd xmmN, [r15 + disp32]
.mem:
    lea edi, [rcx + 0x87]
    call emit_b
    VAR_DISP ecx, ebp
    EMITD ecx
    jmp .ret
.ireg:
    EMIT 0xf2, 0x48, 0x0f, 0x2a     ; cvtsi2sd xmmN, rax
    lea edi, [rcx + 0xc0]
    call emit_b
    jmp .ret
.freg:
    test ecx, ecx
    jz .ret
    EMIT 0x66, 0x0f, 0x28, 0xc8     ; movapd xmm1, xmm0
.ret:
    pop rcx
    pop rbp
    pop rbx
    ret

; emit_push_left(edi = rodzaj) -> r9 = pozycja za odłożeniem lewego argumentu
; w rejestrach na stos (push rax; ułamek: movq rax, xmm0 / push rax;
; dynamiczna: push rax / push rdx) albo -1; zmienia rax
emit_push_left:
    mov r9, -1
    cmp edi, K_REG
    je .one
    cmp edi, K_FREG
    je .flt
    cmp edi, K_DREG
    jne .ret
    EMIT 0x50, 0x52
    jmp .pos
.flt:
    EMIT 0x66, 0x48, 0x0f, 0x7e, 0xc0
.one:
    EMIT 0x50
.pos:
    mov r9, [code_buf + 8]
.ret:
    ret

; make_stub_ecx -> eax = kod rzadki: mov edi, linia / mov esi, ecx / jmp rt_die
; (rodzaj błędu podaje funkcja środowiska w ecx)
make_stub_ecx:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, [cold_buf + 8]
    mov eax, 12
    call cold_need
    mov byte [rax], 0xbf
    mov ecx, [cur_line]
    mov [rax + 1], ecx
    mov word [rax + 5], 0xce89      ; mov esi, ecx
    mov byte [rax + 7], 0xe9
    mov dword [rax + 8], 0
    lea edi, [rbx + 8]
    lea rax, [rt_table]
    mov esi, [rax + RT_DIE*4]
    mov edx, S_COLD | (S_RT << 8)
    call fix_add
    mov eax, ebx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_jc_ecx — jc do błędu z rodzajem w ecx (po rt_darith); zmienia rax
emit_jc_ecx:
    push rdi
    push rsi
    call make_stub_ecx
    mov esi, eax
    mov edi, 2                      ; jc
    call emit_jcc_cold
    pop rsi
    pop rdi
    ret

; emit_jz_div0 — jz do błędu "dzielenie przez zero"; zmienia rax
emit_jz_div0:
    push rdi
    push rsi
    call div0_stub
    mov esi, eax
    mov edi, 4
    call emit_jcc_cold
    pop rsi
    pop rdi
    ret

; int_stub -> eax = błąd "tu potrzebna jest liczba całkowita" w bieżącej linii
int_stub:
    push rdi
    push rsi
    mov edi, RT_DIE
    mov esi, 3
    call make_stub
    pop rsi
    pop rdi
    ret

; mat_nonint(edi = ułamek albo dynamiczna, rsi) — kod: liczba całkowita do rax,
; a dla ułamka błąd w trakcie (materialize dla rodzajów nie-całkowitych);
; zmienia tylko rax
mat_nonint:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    cmp edi, K_DVAR
    jae .dyn
    EMIT 0xe9                       ; ułamek: zawsze błąd
    call int_stub
    mov esi, eax
    mov edi, S_COLD
    call emit_rel
    jmp .ret
.dyn:
    call emit_dyn
    EMIT 0x83, 0xfa, 0x01           ; cmp edx, 1
    call int_stub
    mov esi, eax
    mov edi, 5                      ; jne
    call emit_jcc_cold
.ret:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; truth(edi = rodzaj, rsi = wartość) — kod: rax != 0 dokładnie wtedy, gdy
; liczba jest różna od zera (ułamek: bity << 1, bo -0.0 to też zero);
; zmienia tylko rax
truth:
    cmp edi, K_REG
    jbe materialize
    cmp edi, K_NUM
    ja err_need_num
    push rcx
    push rdx
    push rsi
    push rdi
    cmp edi, K_FCONST
    je .const
    cmp edi, K_FVAR
    je .fvar
    cmp edi, K_FREG
    je .freg
    call emit_dyn
    ; cmp edx, 2 / jne dalej / add rax, rax
    EMIT 0x83, 0xfa, 0x02, 0x75, 0x03, 0x48, 0x01, 0xc0
    jmp .ret
.const:
    add rsi, rsi
    setnz cl
    movzx esi, cl
    xor edi, edi
    call materialize
    jmp .ret
.fvar:
    EMIT 0x49, 0x8b, 0x87
    VAR_DISP ecx, esi
    EMITD ecx
    EMIT 0x48, 0x01, 0xc0
    jmp .ret
.freg:
    EMIT 0x66, 0x48, 0x0f, 0x7e, 0xc0, 0x48, 0x01, 0xc0
.ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; fconst_truth(eax = rodzaj, rdx = wartość) -> stała ułamkowa zamieniona na
; K_CONST 0/1 (dla warunków i not); inne bez zmian
fconst_truth:
    cmp eax, K_FCONST
    jne .ret
    add rdx, rdx
    setnz dl
    movzx edx, dl
    mov eax, K_CONST
.ret:
    ret

; emit_num_out(edi = rodzaj liczby nie-całkowitej, rsi, ecx = 1 z '\n') —
; kod: wypisanie liczby (ułamek: rt_flt_out, dynamiczna: rt_num_out)
emit_num_out:
    push rcx
    cmp edi, K_DVAR
    jae .dyn
    cmp edi, K_FCONST
    je .fc
    cmp edi, K_FVAR
    je .fv
    EMIT 0x66, 0x48, 0x0f, 0x7e, 0xc0   ; movq rax, xmm0
    jmp .flt
.fc:
    EMIT 0x48, 0xb8
    EMITQ rsi
    jmp .flt
.fv:
    EMIT 0x49, 0x8b, 0x87
    VAR_DISP ecx, esi
    EMITD ecx
.flt:
    pop rcx
    mov edi, RT_FLT_OUT
    add edi, ecx
    jmp emit_call_rt
.dyn:
    call emit_dyn
    pop rcx
    mov edi, RT_NUM_OUT
    add edi, ecx
    jmp emit_call_rt

; num_text(edi = rodzaj nie-całkowity, rsi) -> eax, rdx: liczba jako tekst
; (stała: podczas kompilacji, rt_flt_fmt; inaczej rt_flt2text / rt_num2text,
; które zachowują rcx i r8)
num_text:
    cmp edi, K_FCONST
    je .const
    cmp edi, K_DVAR
    jae .dyn
    cmp edi, K_FVAR
    je .fv
    EMIT 0x66, 0x48, 0x0f, 0x7e, 0xc0
    jmp .flt
.fv:
    push rcx
    EMIT 0x49, 0x8b, 0x87
    VAR_DISP ecx, esi
    EMITD ecx
    pop rcx
.flt:
    mov edi, RT_FLT2TEXT
    jmp .call
.dyn:
    call emit_dyn
    mov edi, RT_NUM2TEXT
.call:
    call emit_call_rt
    mov qword [stmt_tmp], 1
    mov eax, K_TREG
    ret
.const:
    push rbx
    push rcx
    push r8
    push r9
    push r10
    push r11
    sub rsp, 40
    mov rax, rsi
    mov rdi, rsp
    call rt_flt_fmt
    mov rbx, rdi
    sub rbx, rsp                    ; długość
    mov r9, [const_buf + 8]
    mov rax, rbx
    call const_need
    mov rdi, rax
    mov rsi, rsp
    mov rcx, rbx
    rep movsb
    add rsp, 40
    mov rdx, rbx
    shl rdx, 32
    or rdx, r9
    mov eax, K_TLIT
    pop r11
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

; neg_num(eax = rodzaj nie-całkowity, rdx) -> eax, rdx: -x
neg_num:
    cmp eax, K_FCONST
    jne .gen
    btc rdx, 63
    ret
.gen:
    push rbx
    mov ebx, eax
    mov edi, eax
    mov rsi, rdx
    cmp ebx, K_DVAR
    jae .dyn
    cmp ebx, K_FVAR
    jne .freg
    EMIT 0x49, 0x8b, 0x87
    VAR_DISP ecx, esi
    EMITD ecx
    jmp .flip
.freg:
    EMIT 0x66, 0x48, 0x0f, 0x7e, 0xc0
.flip:
    ; btc rax, 63 / movq xmm0, rax
    EMIT 0x48, 0x0f, 0xba, 0xf8, 0x3f, 0x66, 0x48, 0x0f, 0x6e, 0xc0
    mov eax, K_FREG
    pop rbx
    ret
.dyn:
    call emit_dyn
    ; cmp edx, 2 / je ułamek / neg rax / jo błąd / jmp dalej / btc rax, 63
    EMIT 0x83, 0xfa, 0x02, 0x74, 0x0b, 0x48, 0xf7, 0xd8
    call emit_jo_ovf
    EMIT 0xeb, 0x05, 0x48, 0x0f, 0xba, 0xf8, 0x3f
    mov eax, K_DREG
    pop rbx
    ret

; num_binop(edi = operator, esi = rodzaj L, r8 = wartość L, ecx = rodzaj P,
;           rdx = wartość P, r9 = pozycja za odłożeniem L albo -1) -> eax, rdx
; obie całkowite (oprócz /): gen_binop; inaczej fgen_binop
num_binop:
    cmp esi, K_REG
    ja fgen_binop
    cmp ecx, K_REG
    ja fgen_binop
    cmp edi, OP_DIV
    je fgen_binop
    jmp gen_binop

; fgen_binop — jak gen_binop, gdy choć jedna strona jest ułamkiem albo
; liczbą dynamiczną (albo dla / na liczbach całkowitych)
fgen_binop:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi                    ; operator
    mov r12d, esi                   ; L
    mov r13, r8
    mov r14d, ecx                   ; P
    mov r15, rdx
    mov rbp, r9
    ; stałe po obu stronach: liczone teraz (te same funkcje co w trakcie)
    cmp r12d, K_CONST
    je .l_const
    cmp r12d, K_FCONST
    jne .run
.l_const:
    cmp r14d, K_CONST
    je .fold
    cmp r14d, K_FCONST
    jne .run
.fold:
    mov rax, r13
    mov edx, 1
    cmp r12d, K_FCONST
    jne .fold_r
    mov edx, 2
.fold_r:
    mov rcx, r15
    mov r8d, 1
    cmp r14d, K_FCONST
    jne .fold_go
    mov r8d, 2
.fold_go:
    mov edi, ebx
    cmp ebx, OP_GE
    jbe .fold_cmp
    call rt_darith
    jc .run                         ; błąd: niech wystąpi w trakcie
    mov ecx, K_CONST
    cmp edx, 2
    jne .fold_kind
    mov ecx, K_FCONST
.fold_kind:
    mov rdx, rax
    mov eax, ecx
    jmp .ret
.fold_cmp:
    call rt_numcmp
    movzx edx, al
    mov eax, K_CONST
    jmp .ret

.run:
    cmp ebx, OP_GE
    jbe .compare
    cmp ebx, OP_DIV
    je .div
    ; + - * // %: obie bez liczb dynamicznych albo jedna strona ułamkiem — ułamki w SSE
    call .static_or_flt
    jc .dyn_arith
    call .fl_setup
    cmp ebx, OP_ADD
    je .f_add
    cmp ebx, OP_SUB
    je .f_sub
    cmp ebx, OP_MUL
    je .f_mul
    call .f_zero_check
    mov edi, RT_FIDIV
    cmp ebx, OP_IDIV
    je .f_call
    mov edi, RT_FMOD
.f_call:
    call emit_call_rt
    jmp .f_done
.f_add:
    EMIT 0xf2, 0x0f, 0x58, 0xc1     ; addsd xmm0, xmm1
    jmp .f_done
.f_sub:
    EMIT 0xf2, 0x0f, 0x5c, 0xc1     ; subsd xmm0, xmm1
    jmp .f_done
.f_mul:
    EMIT 0xf2, 0x0f, 0x59, 0xc1     ; mulsd xmm0, xmm1
.f_done:
    mov eax, K_FREG
    jmp .ret

.div:
    cmp r12d, K_REG
    ja .div_nonint
    cmp r14d, K_REG
    ja .div_nonint
    ; liczba całkowita / liczba całkowita: dokładnie (rt_idiv_flt)
    mov esi, r12d
    mov r8, r13
    mov ecx, r14d
    mov rdx, r15
    mov r9, rbp
    call load_pair
    mov edi, RT_IDIVF
    call emit_call_rt
    call div0_stub
    mov esi, eax
    mov edi, 2                      ; jc
    call emit_jcc_cold
    mov eax, K_FREG
    jmp .ret
.div_nonint:
    call .static_or_flt
    jc .dyn_div
    call .fl_setup
    call .f_zero_check
    EMIT 0xf2, 0x0f, 0x5e, 0xc1     ; divsd xmm0, xmm1
    mov eax, K_FREG
    jmp .ret
.dyn_div:
    call .dyn_setup
    mov edi, OP_DIV
    call .call_darith
    EMIT 0x66, 0x48, 0x0f, 0x6e, 0xc0   ; movq xmm0, rax (wynik zawsze ułamkiem)
    mov eax, K_FREG
    jmp .ret
.dyn_arith:
    call .dyn_setup
    mov edi, ebx
    call .call_darith
    mov eax, K_DREG
    jmp .ret

.compare:
    ; obie strony ułamkami (albo stałymi całkowitymi dokładnie zapisywalnymi
    ; jako ułamek): ucomisd; inaczej dokładnie przez rt_numcmp
    mov eax, r12d
    mov rdx, r13
    call .exact_flt
    jc .dyn_cmp
    mov eax, r14d
    mov rdx, r15
    call .exact_flt
    jc .dyn_cmp
    call .fl_setup
    cmp ebx, OP_EQ
    je .c_eq
    cmp ebx, OP_NE
    je .c_ne
    ; < <=: ucomisd xmm1, xmm0 (P > L); > >=: ucomisd xmm0, xmm1;
    ; seta / setae — nan daje fałsz, a if/while zamieni to na jbe / jb
    mov edi, 0xc8
    cmp ebx, OP_GT
    jb .c_ord
    mov edi, 0xc1
.c_ord:
    EMIT 0x66, 0x0f, 0x2e
    call emit_b
    mov edi, 7                      ; a
    cmp ebx, OP_LE
    je .c_ae
    cmp ebx, OP_GE
    jne .c_set
.c_ae:
    mov edi, 3                      ; ae
.c_set:
    call set_result
    mov eax, K_REG
    jmp .ret
.c_eq:
    ; ucomisd / sete al / setnp cl / and al, cl / movzx eax, al
    EMIT 0x66, 0x0f, 0x2e, 0xc1, 0x0f, 0x94, 0xc0, 0x0f, 0x9b, 0xc1, 0x20, 0xc8, 0x0f, 0xb6, 0xc0
    mov eax, K_REG
    jmp .ret
.c_ne:
    ; ucomisd / setne al / setp cl / or al, cl / movzx eax, al
    EMIT 0x66, 0x0f, 0x2e, 0xc1, 0x0f, 0x95, 0xc0, 0x0f, 0x9a, 0xc1, 0x08, 0xc8, 0x0f, 0xb6, 0xc0
    mov eax, K_REG
    jmp .ret
.dyn_cmp:
    call .dyn_setup
    EMIT 0xbf                       ; mov edi, operator
    EMITD ebx
    mov edi, RT_NUMCMP
    call emit_call_rt
    mov eax, K_REG
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; --- pomocnicze (rejestry jak w fgen_binop) ---

; CF = 1, gdy jest strona dynamiczna, a druga nie jest ułamkiem
; (wynik może być liczbą całkowitą — rt_darith)
.static_or_flt:
    mov eax, r12d
    call ncls
    mov edx, ecx
    mov eax, r14d
    call ncls
    cmp edx, 3
    je .sf_l
    cmp ecx, 3
    jne .sf_ok
    cmp edx, 2                      ; P dynamiczna: L musi być ułamkiem
    je .sf_ok
    stc
    ret
.sf_l:
    cmp ecx, 2
    je .sf_ok
    stc
    ret
.sf_ok:
    clc
    ret

; .exact_flt(eax, rdx) -> CF = 0, gdy to ułamek (statycznie) albo stała
; całkowita |c| <= 2^53 (zamiana na ułamek bez zaokrąglenia)
.exact_flt:
    cmp eax, K_CONST
    je .ef_const
    cmp eax, K_FCONST
    jb .ef_no
    cmp eax, K_FREG
    ja .ef_no
    clc
    ret
.ef_const:
    mov rcx, 1 << 53
    add rdx, rcx
    add rcx, rcx
    cmp rdx, rcx
    ja .ef_no
    clc
    ret
.ef_no:
    stc
    ret

; .f_zero_check — dzielnik w xmm1 równy 0 (także -0.0): błąd
.f_zero_check:
    ; movq rcx, xmm1 / add rcx, rcx / jz błąd
    EMIT 0x66, 0x48, 0x0f, 0x7e, 0xc9, 0x48, 0x01, 0xc9
    jmp emit_jz_div0

; .call_darith(edi = operator) — mov edi, op / call rt_darith / jc błąd
.call_darith:
    push rdi
    EMIT 0xbf
    pop rdi
    EMITD edi
    mov edi, RT_DARITH
    call emit_call_rt
    jmp emit_jc_ecx

; .fl_setup — kod: L do xmm0, P do xmm1
.fl_setup:
    cmp r14d, K_REG
    je .fs_rreg
    cmp r14d, K_FREG
    je .fs_rreg
    cmp r14d, K_DREG
    je .fs_rreg
    call .l_xmm0_unpush             ; P w pamięci albo stała
    mov edi, r14d
    mov rsi, r15
    mov r10d, 1
    jmp emit_xload
.fs_rreg:
    mov edi, r14d                   ; P w rejestrach: najpierw do xmm1
    mov rsi, r15
    mov r10d, 1
    call emit_xload
    jmp .l_xmm0_pop
; L do xmm0, gdy P nie zmienił rejestrów (odłożenie L może zostać cofnięte)
.l_xmm0_unpush:
    cmp r12d, K_REG
    je .lu_one
    cmp r12d, K_FREG
    je .lu_one
    cmp r12d, K_DREG
    je .lu_two
    mov edi, r12d
    mov rsi, r13
    xor r10d, r10d
    jmp emit_xload
.lu_one:
    cmp r12d, K_FREG
    jne .lu_int
    cmp rbp, [code_buf + 8]
    jne .lu_int
    sub qword [code_buf + 8], 6     ; movq rax, xmm0 / push rax cofnięte: L dalej w xmm0
    ret
.lu_int:
    mov r9, rbp
    call unpush                     ; rax = L (liczba albo bity ułamka)
    cmp r12d, K_FREG
    je .lu_f
    EMIT 0xf2, 0x48, 0x0f, 0x2a, 0xc0   ; cvtsi2sd xmm0, rax
    ret
.lu_f:
    EMIT 0x66, 0x48, 0x0f, 0x6e, 0xc0   ; movq xmm0, rax
    ret
.lu_two:
    call .unpush2
    mov edi, K_DREG
    xor r10d, r10d
    jmp emit_xload
; L do xmm0 ze stosu (P jest już w xmm1)
.l_xmm0_pop:
    cmp r12d, K_REG
    je .lp_reg
    cmp r12d, K_FREG
    je .lp_f
    cmp r12d, K_DREG
    je .lp_d
    mov edi, r12d
    mov rsi, r13
    xor r10d, r10d
    jmp emit_xload
.lp_reg:
    EMIT 0x58, 0xf2, 0x48, 0x0f, 0x2a, 0xc0     ; pop rax / cvtsi2sd xmm0, rax
    ret
.lp_f:
    EMIT 0x58, 0x66, 0x48, 0x0f, 0x6e, 0xc0     ; pop rax / movq xmm0, rax
    ret
.lp_d:
    EMIT 0x5a, 0x58                             ; pop rdx / pop rax
    mov edi, K_DREG
    xor r10d, r10d
    jmp emit_xload
; cofnięcie push rax / push rdx albo pop rdx / pop rax
.unpush2:
    cmp rbp, [code_buf + 8]
    jne .u2_pop
    sub qword [code_buf + 8], 2
    ret
.u2_pop:
    EMIT 0x5a, 0x58
    ret

; .dyn_setup — kod: L do rax, edx; P do rcx, r8d
.dyn_setup:
    cmp r14d, K_REG
    je .ds_rreg
    cmp r14d, K_FREG
    je .ds_rreg
    cmp r14d, K_DREG
    je .ds_rreg
    call .l_dyn_unpush
    mov edi, r14d
    mov rsi, r15
    jmp emit_dyn_rcx
.ds_rreg:
    mov edi, r14d
    mov rsi, r15
    call emit_dyn
    EMIT 0x48, 0x89, 0xc1, 0x41, 0x89, 0xd0     ; mov rcx, rax / mov r8d, edx
    jmp .l_dyn_pop
.l_dyn_unpush:
    cmp r12d, K_REG
    je .ldu_one
    cmp r12d, K_FREG
    je .ldu_one
    cmp r12d, K_DREG
    je .unpush2
    mov edi, r12d
    mov rsi, r13
    jmp emit_dyn
.ldu_one:
    mov r9, rbp
    call unpush
.l_tag:
    mov edi, 1                      ; mov edx, rodzaj
    cmp r12d, K_FREG
    jne .l_tag_go
    mov edi, 2
.l_tag_go:
    EMIT 0xba
    EMITD edi
    ret
.l_dyn_pop:
    cmp r12d, K_REG
    je .ldp_one
    cmp r12d, K_FREG
    je .ldp_one
    cmp r12d, K_DREG
    je .ldp_two
    mov edi, r12d
    mov rsi, r13
    jmp emit_dyn
.ldp_one:
    EMIT 0x58
    jmp .l_tag
.ldp_two:
    EMIT 0x5a, 0x58
    ret

; ===================== moduł math: math.f(...), math.pi, math.e =====================

; rodzaje funkcji (math_desc): bajty rodzaj, id dla rt_math1, id dla rt_math2,
; najmniej i najwięcej argumentów (255 = dowolnie wiele)
%define MT_ABS   0
%define MT_MM    1              ; min / max
%define MT_POW   2
%define MT_F1    3              ; ułamek z jednego argumentu
%define MT_I1    4              ; floor / ceil / trunc: liczba całkowita
%define MT_ROUND 5
%define MT_F2    6              ; atan2, hypot
%define MT_LOG   7
%define MT_RAND  8
%define MT_CONST 9
[section .rodata]
math_desc:
    db MT_ABS,  M1_ABS,   0,         1, 1   ; abs
    db MT_MM,   0,        M2_MIN,    2, 255 ; min
    db MT_MM,   0,        M2_MAX,    2, 255 ; max
    db MT_POW,  0,        M2_POW,    2, 2   ; pow
    db MT_F1,   M1_SQRT,  0,         1, 1   ; sqrt
    db MT_I1,   M1_FLOOR, 0,         1, 1   ; floor
    db MT_I1,   M1_CEIL,  0,         1, 1   ; ceil
    db MT_ROUND, M1_ROUND, M2_ROUND, 1, 2   ; round
    db MT_I1,   M1_TRUNC, 0,         1, 1   ; trunc
    db MT_F1,   M1_SIN,   0,         1, 1   ; sin
    db MT_F1,   M1_COS,   0,         1, 1   ; cos
    db MT_F1,   M1_TAN,   0,         1, 1   ; tan
    db MT_F1,   M1_ASIN,  0,         1, 1   ; asin
    db MT_F1,   M1_ACOS,  0,         1, 1   ; acos
    db MT_F1,   M1_ATAN,  0,         1, 1   ; atan
    db MT_F2,   0,        M2_ATAN2,  2, 2   ; atan2
    db MT_LOG,  M1_LOG,   M2_LOG,    1, 2   ; log
    db MT_F1,   M1_LOG2,  0,         1, 1   ; log2
    db MT_F1,   M1_LOG10, 0,         1, 1   ; log10
    db MT_F1,   M1_EXP,   0,         1, 1   ; exp
    db MT_F2,   0,        M2_HYPOT,  2, 2   ; hypot
    db MT_RAND, 0,        M2_RANDINT, 0, 2  ; random
    db MT_CONST, 0,       0,         0, 0   ; pi
    db MT_CONST, 0,       0,         0, 0   ; e
math_consts: dq 0x400921fb54442d18, 0x4005bf0a8b145769
__SECT__

; math_call (r12 na '.' za słowem math) -> eax, rdx
; Argumenty liczone od lewej; każdy jako liczba dynamiczna (rax, edx; drugi
; w rcx, r8d) dla rt_math1 / rt_math2. Wcześniejszy argument w rejestrach
; czeka na stosie (push rax / push rdx); stała albo zmienna — bez kodu, do
; chwili wywołania. Same stałe (poza random): wynik liczony już teraz.
math_call:
    push rbx
    push rbp
    push r12                        ; (miejsce; r12 przywracane niżej)
    push r14
    push r15
    sub rsp, 48                     ; [rsp] opis, [rsp+8] klasy argumentów (bity: 2
                                    ; całkowita, 4 ułamek, 8 dynamiczna), [rsp+16] liczba
                                    ; argumentów, [rsp+32] klasa 1. arg., [rsp+40] P stała >= 0
    test byte [imp_mods], POL_MATH
    jz err_math_import
    inc r12
    mov rbx, r12
    call skip_ident
    mov rsi, rbx
    mov rdx, r12
    sub rdx, rbx
    jz err_math_fn
    call imp_math
    test eax, eax
    js err_math_fn
    test ecx, ecx
    jz err_math_only
    lea rcx, [math_desc]
    lea rcx, [rcx + rax*4]
    add rcx, rax                    ; 5 bajtów na wpis
    mov [rsp], rcx
    cmp byte [rcx], MT_CONST
    jne .func
    sub eax, 22                     ; pi, e
    lea rcx, [math_consts]
    mov rdx, [rcx + rax*8]
    mov eax, K_FCONST
    jmp .ret
.func:
    call ws
    AT '('
    jne err_math_paren
    mov rax, [paren_depth]
    cmp rax, [max_depth]
    jae err_too_deep
    cmp rsp, [hard_floor]
    jb err_too_deep
    inc qword [paren_depth]
    inc r12
    mov qword [rsp + 8], 0
    mov qword [rsp + 16], 0
    mov qword [rsp + 32], 0
    xor r14d, r14d                  ; akumulator: rodzaj (-1 = na stosie)
    xor r15d, r15d                  ;   wartość
    call ws
    AT ')'
    je .args_done
.arg:
    xor edi, edi
    call expr
    cmp eax, K_NUM
    ja err_need_num
    mov ebx, eax                    ; argument
    mov rbp, rdx
    call ncls
    mov eax, 1
    shl eax, cl                     ; bit klasy
    or [rsp + 8], rax
    cmp qword [rsp + 16], 0
    jne .not_first
    mov [rsp + 32], rax             ; klasa pierwszego argumentu
.not_first:
    inc qword [rsp + 16]
    ; P stała >= 0 (dla pow liczby całkowitej)
    xor ecx, ecx
    cmp ebx, K_CONST
    jne .nc
    test rbp, rbp
    js .nc
    mov ecx, 1
.nc:
    mov [rsp + 40], rcx             ; (ważne dla ostatniego argumentu)
    call ws
    cmp qword [rsp + 16], 1
    ja .combine
    ; pierwszy argument: stała / zmienna czeka, wartość w rejestrach na stos
    mov r14d, ebx
    mov r15, rbp
    cmp ebx, K_REG
    je .push_first
    cmp ebx, K_FREG
    je .push_first
    cmp ebx, K_DREG
    jne .next
.push_first:
    AT ','
    jne .next                       ; jedyny argument: zostaje w rejestrach
    mov edi, ebx
    mov rsi, rbp
    call emit_dyn
    EMIT 0x50, 0x52                 ; push rax / push rdx
    mov r14d, -1
    jmp .next
.combine:
    ; akumulator (r14d, r15) z argumentem (ebx, rbp) -> rt_math2
    mov rcx, [rsp]
    movzx edi, byte [rcx + 2]
    call .call2
.next:
    AT ','
    jne .args_end
    inc r12
    call ws
    jmp .arg
.args_end:
    AT ')'
    jne err_rparen_e
.args_done:
    inc r12
    dec qword [paren_depth]
    ; liczba argumentów
    mov rcx, [rsp]
    mov rax, [rsp + 16]
    movzx edx, byte [rcx + 3]
    cmp rax, rdx
    jb err_math_args
    movzx edx, byte [rcx + 4]
    cmp rax, rdx
    ja err_math_args
    movzx ebx, byte [rcx]           ; rodzaj funkcji
    cmp ebx, MT_RAND
    jne .arity_ok
    cmp rax, 1
    je err_math_args                ; random() albo random(a, b)
.arity_ok:
    cmp rax, 1
    ja .result2
    jb .zero_args
    ; --- jeden argument (r14d, r15) ---
    mov rdx, [rsp + 8]              ; klasa
    cmp ebx, MT_I1
    je .int1
    cmp ebx, MT_ROUND
    jne .call1
.int1:
    cmp edx, 2
    jne .call1
    mov edi, r14d                   ; liczba całkowita: bez zmian
    mov rsi, r15
    call materialize
    mov eax, K_REG
    cmp r14d, K_CONST
    jne .ret
    mov eax, K_CONST
    mov rdx, r15
    jmp .ret
.call1:
    mov rcx, [rsp]
    movzx ebp, byte [rcx + 1]       ; id rt_math1
    ; stała: wynik od razu
    cmp r14d, K_CONST
    je .fold1
    cmp r14d, K_FCONST
    jne .gen1
.fold1:
    mov rax, r15
    mov edx, 1
    cmp r14d, K_FCONST
    jne .f1_go
    mov edx, 2
.f1_go:
    mov edi, ebp
    call rt_math1
    jc .gen1
    jmp .folded
.gen1:
    mov edi, r14d
    mov rsi, r15
    call emit_dyn
    EMIT 0xbf                       ; mov edi, id
    EMITD ebp
    mov edi, RT_MATH1
    call emit_call_rt
    call emit_jc_ecx
    ; rodzaj wyniku
    cmp ebx, MT_ABS
    je .by_class
    cmp ebx, MT_F1
    je .freg
    cmp ebx, MT_LOG
    je .freg
    mov eax, K_REG                  ; floor, ceil, trunc, round
    jmp .ret
.zero_args:
    mov edi, RT_RANDOM              ; random()
    call emit_call_rt
    jmp .freg
.result2:
    ; wynik rt_math2 w rax, edx (albo stała w r14d, r15)
    cmp r14d, K_CONST
    je .const_res
    cmp r14d, K_FCONST
    je .const_res
    cmp ebx, MT_MM
    je .mm_kind
    cmp ebx, MT_F2
    je .freg
    cmp ebx, MT_LOG
    je .freg
    cmp ebx, MT_RAND
    je .reg
    cmp ebx, MT_ROUND
    jne .pow_kind
    mov rdx, [rsp + 32]             ; round(x, n): klasa x
    jmp .by_class_d
.pow_kind:
    mov rdx, [rsp + 8]
    test edx, 4
    jnz .freg                       ; jest ułamek: wynik ułamkiem
    cmp edx, 2
    jne .dreg
    cmp qword [rsp + 40], 0         ; liczby całkowite: P stała >= 0 -> całkowita
    jne .reg
    jmp .dreg
.mm_kind:
    mov rdx, [rsp + 8]
    jmp .by_class_d
.by_class:
    mov rdx, [rsp + 8]
.by_class_d:
    cmp edx, 2
    je .reg
    cmp edx, 4
    je .freg
.dreg:
    mov eax, K_DREG
    jmp .ret
.reg:
    mov eax, K_REG
    jmp .ret
.freg:
    EMIT 0x66, 0x48, 0x0f, 0x6e, 0xc0   ; movq xmm0, rax
    mov eax, K_FREG
    jmp .ret
.const_res:
    mov eax, r14d
    mov rdx, r15
    jmp .ret
.folded:
    mov ecx, K_CONST
    cmp edx, 2
    jne .fd
    mov ecx, K_FCONST
.fd:
    mov rdx, rax
    mov eax, ecx
.ret:
    add rsp, 48
    pop r15
    pop r14
    add rsp, 8                      ; (r12 zostaje za wywołaniem)
    pop rbp
    pop rbx
    ret

; .call2(edi = id rt_math2): akumulator (r14d, r15; -1 = na stosie) op
; argument (ebx, rbp) -> akumulator: stała (gdy dało się policzyć teraz)
; albo -1 i kod zostawia wynik w rax, edx (wtedy dla kolejnych argumentów
; min / max: na stos)
.call2:
    push rdi
    ; obie stałe (i nie random): od razu
    cmp edi, M2_RANDINT
    je .c2_gen
    cmp r14d, K_CONST
    je .c2_l
    cmp r14d, K_FCONST
    jne .c2_gen
.c2_l:
    cmp ebx, K_CONST
    je .c2_fold
    cmp ebx, K_FCONST
    jne .c2_gen
.c2_fold:
    mov rax, r15
    mov edx, 1
    cmp r14d, K_FCONST
    jne .c2_r
    mov edx, 2
.c2_r:
    mov rcx, rbp
    mov r8d, 1
    cmp ebx, K_FCONST
    jne .c2_go
    mov r8d, 2
.c2_go:
    call rt_math2
    jc .c2_gen
    mov r14d, K_CONST
    cmp edx, 2
    jne .c2_k
    mov r14d, K_FCONST
.c2_k:
    mov r15, rax
    pop rdi
    ret
.c2_gen:
    cmp r14d, -1
    je .c2_stack
    ; akumulator czeka (stała / zmienna)
    cmp ebx, K_REG
    je .c2_preg
    cmp ebx, K_FREG
    je .c2_preg
    cmp ebx, K_DREG
    je .c2_preg
    mov edi, r14d
    mov rsi, r15
    call emit_dyn
    mov edi, ebx
    mov rsi, rbp
    call emit_dyn_rcx
    jmp .c2_call
.c2_preg:
    mov edi, ebx
    mov rsi, rbp
    call emit_dyn
    EMIT 0x48, 0x89, 0xc1, 0x41, 0x89, 0xd0     ; mov rcx, rax / mov r8d, edx
    mov edi, r14d
    mov rsi, r15
    call emit_dyn
    jmp .c2_call
.c2_stack:
    cmp ebx, K_REG
    je .c2_sreg
    cmp ebx, K_FREG
    je .c2_sreg
    cmp ebx, K_DREG
    je .c2_sreg
    mov edi, ebx
    mov rsi, rbp
    call emit_dyn_rcx
    EMIT 0x5a, 0x58                 ; pop rdx / pop rax
    jmp .c2_call
.c2_sreg:
    mov edi, ebx
    mov rsi, rbp
    call emit_dyn
    EMIT 0x48, 0x89, 0xc1, 0x41, 0x89, 0xd0, 0x5a, 0x58
.c2_call:
    EMIT 0xbf                       ; mov edi, id
    mov edi, [rsp]
    EMITD edi
    mov edi, RT_MATH2
    call emit_call_rt
    call emit_jc_ecx
    mov r14d, -1
    pop rdi
    AT ','
    jne .c2_ret
    EMIT 0x50, 0x52                 ; dalsze argumenty min / max: wynik na stos
.c2_ret:
    ret
