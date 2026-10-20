; comp.asm — kompilator Fih 0.2: parser, generator kodu x86-64, JIT i zapis ELF
;
; Program jest czytany linia po linii (jedna instrukcja na linię) i od razu
; tłumaczony na kod maszynowy. Cały plik jest sprawdzany przed uruchomieniem:
; błąd składni kończy kompilację, zanim cokolwiek zostanie wypisane.
;
; Obraz programu (ten sam w pamięci JIT i w pliku ELF):
;   [rt: środowisko uruchomieniowe][nagłówek 16 B][kod][kod rzadki][stałe]
; Kod rzadki to wywołania błędów (przepełnienie, dzielenie przez zero, zmienna
; bez wartości) — poza główną ścieżką, żeby jej nie wydłużać. Skoki między
; częściami obrazu są poprawiane po złożeniu (tablica fix_buf).
;
; Wygenerowany kod: wartość wyrażenia w rax, drugi argument w rcx, zmienne
; w obszarze danych pod r15 (16 B na zmienną: wartość, flaga "ma wartość").
;
; Wyrażenie opisuje para (rodzaj, wartość): K_CONST — znana liczba,
; K_VAR — zmienna (nr), K_REG — policzone w rax. Dzięki temu stałe są
; składane podczas kompilacji, a zmienne trafiają do instrukcji jako operand
; pamięciowy. Rejestry parsera: r12 = kursor, r13 = koniec badanego obszaru.
%include "fih.inc"
default rel

global comp_compile, comp_run_jit, comp_write_elf
global blank, skip_ident, end_check, const_need, const_buf, buf_need, ident_tab
extern imp_statement, imp_policy, imp_need_base
extern fmt_int
extern die, die_noline, die_name, cur_line, stack_budget, rt_table, rt_begin, write_file2

%define K_CONST 0
%define K_VAR   1
%define K_REG   2
; teksty (rodzaj > K_REG): K_TREG — w rax (adres) i rdx (długość),
; K_TLIT — stała: wartość = przesunięcie w stałych | długość << 32,
; K_TVAR — zmienna tekstowa (nr)
%define K_TREG  3
%define K_TLIT  4
%define K_TVAR  5

; części obrazu (dla poprawek adresów)
%define S_RT    0
%define S_HOT   1
%define S_COLD  2
%define S_CONST 3

; indeksy w rt_table
%define RT_SIZE    0
%define RT_WRITE   1
%define RT_INT_NL  2
%define RT_EXIT    3
%define RT_DIE     4
%define RT_DIE_VAR 5
%define RT_INT     6
%define RT_INPUT   7
%define RT_INPUTCHAR 8
%define RT_SANDBOX 9
%define RT_TMPRESET 10
%define RT_CAT     11
%define RT_INT2TEXT 12
%define RT_SETTEXT 13
%define RT_APPEND  14
%define RT_STREQ   15
%define RT_LEN     16
%define RT_INDEX   17
%define RT_SLICE   18
%define RT_INPUTTEXT 19
%define RT_NL      20
%define RT_CATINT  21

%define HDR_SIZE 16

; operatory dwuargumentowe
%define OP_OR   1
%define OP_AND  2
%define OP_EQ   3
%define OP_NE   4
%define OP_LT   5
%define OP_LE   6
%define OP_GT   7
%define OP_GE   8
%define OP_ADD  9
%define OP_SUB  10
%define OP_MUL  11
%define OP_DIV  12
%define OP_MOD  13

%define P_NOT 3
%define P_CMP 4

; słowa kluczowe (kw_id)
%define KW_PRINT    1
%define KW_CALC     2
%define KW_IF       3
%define KW_WHILE    4
%define KW_ELSE     5
%define KW_BREAK    6
%define KW_CONTINUE 7
%define KW_AND      8
%define KW_OR       9
%define KW_NOT      10
%define KW_WRITE    11
%define KW_INPUT    12      ; funkcje wbudowane: KW_INPUT ... KW_EOF
%define KW_INPUTCHAR 13
%define KW_INPUTOK  14
%define KW_EOF      15

; bloki
%define B_IF    1
%define B_ELSE  2
%define B_WHILE 3
%define MAX_BLOCKS 65536
%define MAX_VARS   65536
%define HSLOTS     (1 << 17)

; wpis stosu bloków (32 B)
%define BL_KIND   0
%define BL_FALSE  4         ; lista skoków "warunek fałszywy" (while: wyjścia z pętli)
%define BL_END    8         ; lista skoków na koniec łańcucha if / else
%define BL_START  12        ; początek pętli (while)
%define BL_MARK   16        ; stan stosu dowodów przy otwarciu bloku
%define BL_LINE   24

%define BASE 0x400000

; EMIT b1, b2, ... — dopisuje stałe bajty do kodu (zmienia tylko rax)
%macro EMIT 1-*
    mov eax, %0
    call code_need
  %assign %%i 0
  %rep %0
    mov byte [rax + %%i], %1
    %rotate 1
    %assign %%i %%i + 1
  %endrep
%endmacro

; EMITD x — dopisuje 4 bajty (x nie może być eax)
%macro EMITD 1
    mov eax, 4
    call code_need
    mov dword [rax], %1
%endmacro

; EMITQ x — dopisuje 8 bajtów (x nie może być rax)
%macro EMITQ 1
    mov eax, 8
    call code_need
    mov qword [rax], %1
%endmacro

; AT znak -> ZF=1, gdy w r12 (przed r13) stoi ten znak
%macro AT 1
    cmp r12, r13
    jae %%no
    cmp byte [r12], %1
    jmp %%done
%%no:
    test r12, r12           ; ZF = 0
%%done:
%endmacro

; CERR etykieta, "komunikat" — błąd kompilacji z numerem linii
%macro CERR 2
%1:
    lea rdi, [%%msg]
    mov esi, %%len
    jmp die
[section .rodata]
%%msg: db %2
%%len equ $ - %%msg
__SECT__
%endmacro

section .rodata
; 1 dla [A-Za-z0-9_]
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
; priorytet operatora (indeks OP_*)
prec_tab: db 0, 1, 2, 4, 4, 4, 4, 4, 4, 5, 5, 6, 6, 6
; warunek procesora dla porównań: e, ne, l, le, g, ge
cc_tab:   db 0, 0, 0, 4, 5, 0x0c, 0x0e, 0x0f, 0x0d, 0, 0, 0, 0, 0
; słowa kluczowe: długość, tekst; 0 = koniec
kw_tab:
    db 5, "print"
    db 4, "calc"
    db 2, "if"
    db 5, "while"
    db 4, "else"
    db 5, "break"
    db 8, "continue"
    db 3, "and"
    db 2, "or"
    db 3, "not"
    db 5, "write"
    db 5, "input"
    db 9, "inputchar"
    db 7, "inputok"
    db 3, "eof"
    db 0
; funkcje wbudowane rozpoznawane po nawiasie (nie są słowami zarezerwowanymi)
fn_len:       db "len"
fn_inputtext: db "inputtext"
kw_not: db "not"
kw_and: db "and"
kw_or:  db "or"
msg_nomem:  db "brak pamięci"
msg_nomem_len equ $ - msg_nomem
msg_unk1:   db "nieznana zmienna '"
msg_unk1_len equ $ - msg_unk1
msg_q:      db "'"
msg_var1:   db "zmienna '"
msg_var1_len equ $ - msg_var1
msg_is_num: db "' jest liczbą, nie tekstem"
msg_is_num_len equ $ - msg_is_num
msg_is_text: db "' jest tekstem, nie liczbą"
msg_is_text_len equ $ - msg_is_text

section .bss
code_buf:  resq 3           ; ptr, len, cap
cold_buf:  resq 3
const_buf: resq 3
fix_buf:   resq 3           ; poprawki: dd poz, dd cel, dd części (źródło | cel << 8), dd 0
src_end:   resq 1
line_eol:  resq 1
max_depth: resq 1           ; limit zagnieżdżenia nawiasów (jak w expr.asm)
hard_floor: resq 1          ; twarda granica stosu parsera
paren_depth: resq 1
str_nl:    resd 1           ; 1 = print (napis z '\n'), 0 = write
stub_ovf:  resd 1           ; wywołania błędów dla bieżącej linii (-1 = brak)
stub_div:  resd 1
last_set_pos: resd 1        ; ostatnie "setcc al; movzx eax, al": początek,
last_set_end: resd 1        ;   koniec i warunek (do zamiany na skok warunkowy)
last_set_cc:  resd 1
nvars:     resq 1
block_sp:  resq 1
proof_sp:  resq 1
pol_off:   resq 1           ; opis uprawnień (imp_policy) w stałych
seen_stmt: resq 1           ; 1 = była już instrukcja inna niż import
stmt_tmp:  resq 1           ; 1 = wyrażenie użyło obszaru tymczasowego tekstów
img_ptr:   resq 1           ; złożony obraz programu
img_len:   resq 1
data_size: resq 1
img_cap:   resq 1
htab:      resb HSLOTS * 16 ; tablica nazw: dq wskaźnik, dd długość, dd numer + 1
var_ptr:   resq MAX_VARS
var_len:   resd MAX_VARS
var_off:   resd MAX_VARS
var_assigned: resb MAX_VARS ; przypisana we wcześniejszej instrukcji (w tekście)
var_type:  resb MAX_VARS    ; 0 = jeszcze nieznany, 1 = liczba, 2 = tekst
var_proven:   resb MAX_VARS ; na pewno ma wartość w tym miejscu programu
proof_stack:  resd MAX_VARS
blocks:    resb MAX_BLOCKS * 32
elf_hdr:   resb 192

section .text

; ===================== bufory =====================

; buf_need(rdi=bufor, rax=n) -> rax = miejsce na n bajtów (len += n);
; zmienia tylko rax
buf_need:
    push rcx
    mov rcx, [rdi + 8]
    add rcx, rax
    cmp rcx, [rdi + 16]
    ja .grow
.ok:
    mov rax, [rdi + 8]
    mov [rdi + 8], rcx
    add rax, [rdi]
    pop rcx
    ret
.grow:
    push rbx
    push rbp
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rbx, rdi
    mov rbp, rcx            ; potrzebna długość
    mov r9, [rbx + 16]
    add r9, r9
    cmp r9, rbp
    cmovb r9, rbp
    mov eax, 1 << 20
    cmp r9, rax
    cmovb r9, rax
    add r9, 4095
    and r9, -4096
    mov rdi, [rbx]
    test rdi, rdi
    jz .fresh
    mov eax, SYS_MREMAP
    mov rsi, [rbx + 16]
    mov rdx, r9
    mov r10d, MREMAP_MAYMOVE
    syscall
    jmp .check
.fresh:
    mov eax, SYS_MMAP
    xor edi, edi
    mov rsi, r9
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    push r9
    xor r9d, r9d
    syscall
    pop r9
.check:
    cmp rax, -4095
    jae nomem
    mov [rbx], rax
    mov [rbx + 16], r9
    mov rcx, rbp
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rbp
    pop rbx
    jmp .ok

nomem:
    lea rdi, [msg_nomem]
    mov esi, msg_nomem_len
    jmp die_noline

code_need:
    push rdi
    lea rdi, [code_buf]
    call buf_need
    pop rdi
    ret

cold_need:
    push rdi
    lea rdi, [cold_buf]
    call buf_need
    pop rdi
    ret

const_need:
    push rdi
    lea rdi, [const_buf]
    call buf_need
    pop rdi
    ret

; code_len -> eax = bieżąca pozycja w kodzie
%macro CODE_POS 1
    mov %1, [code_buf + 8]
%endmacro

; fix_add(edi=pozycja, esi=przesunięcie celu, edx=części) — zmienia tylko rax
fix_add:
    push rdi
    lea rdi, [fix_buf]
    mov eax, 16
    call buf_need
    pop rdi
    mov [rax], edi
    mov [rax + 4], esi
    mov [rax + 8], edx
    mov dword [rax + 12], 0
    ret

; emit_rel(edi=część celu, esi=przesunięcie celu) — 4 bajty rel32 w kodzie,
; uzupełniane po złożeniu obrazu; zmienia tylko rax
emit_rel:
    push rdx
    push rdi
    EMITD 0
    mov edx, [rsp]          ; część celu
    shl edx, 8
    or edx, S_HOT
    CODE_POS rax
    lea edi, [rax - 4]
    call fix_add
    pop rdi
    pop rdx
    ret

; emit_call_rt(edi=indeks RT_*) — call do funkcji środowiska; zmienia rax, rsi, rdi
emit_call_rt:
    lea rax, [rt_table]
    mov esi, [rax + rdi*4]
    EMIT 0xe8
    mov edi, S_RT
    jmp emit_rel

; make_stub(edi=RT_DIE/RT_DIE_VAR, esi=argument) -> eax = przesunięcie w kodzie
; rzadkim: mov edi, linia / mov esi, argument / jmp funkcja środowiska
make_stub:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, [cold_buf + 8]
    mov eax, 15
    call cold_need
    mov byte [rax], 0xbf
    mov ecx, [cur_line]
    mov [rax + 1], ecx
    mov byte [rax + 5], 0xbe
    mov [rax + 6], esi
    mov byte [rax + 10], 0xe9
    mov dword [rax + 11], 0
    lea edi, [rbx + 11]
    lea rax, [rt_table]
    mov ecx, [rsp]          ; indeks funkcji
    mov esi, [rax + rcx*4]
    mov edx, S_COLD | (S_RT << 8)
    call fix_add
    mov eax, ebx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; emit_jcc_cold(edi=warunek, esi=przesunięcie w kodzie rzadkim) — zmienia rax
emit_jcc_cold:
    push rdi
    mov eax, 2
    call code_need
    mov byte [rax], 0x0f
    add dil, 0x80
    mov [rax + 1], dil
    mov edi, S_COLD
    call emit_rel
    pop rdi
    ret

; emit_jo_ovf — jo do błędu przepełnienia w bieżącej linii; zmienia rax
emit_jo_ovf:
    push rdi
    push rsi
    mov esi, [stub_ovf]
    cmp esi, -1
    jne .have
    mov edi, RT_DIE
    xor esi, esi
    call make_stub
    mov [stub_ovf], eax
    mov esi, eax
.have:
    xor edi, edi            ; jo
    call emit_jcc_cold
    pop rsi
    pop rdi
    ret

; div0_stub -> eax = błąd dzielenia przez zero w bieżącej linii
div0_stub:
    mov eax, [stub_div]
    cmp eax, -1
    jne .done
    push rdi
    push rsi
    mov edi, RT_DIE
    mov esi, 1
    call make_stub
    mov [stub_div], eax
    pop rsi
    pop rdi
.done:
    ret

; emit_j32(edi=warunek albo -1 dla jmp, rsi=adres głowy listy) — skok
; z rel32 dopisanym do listy (pole rel32 trzyma poprzednią pozycję + 1)
emit_j32:
    cmp edi, -1
    je .jmp
    mov eax, 2
    call code_need
    mov byte [rax], 0x0f
    lea ecx, [rdi + 0x80]
    mov [rax + 1], cl
    jmp .slot
.jmp:
    EMIT 0xe9
.slot:
    mov ecx, [rsi]
    EMITD ecx
    CODE_POS rax
    sub eax, 3              ; pozycja pola + 1
    mov [rsi], eax
    ret

; resolve(edi=głowa listy, esi=pozycja celu) — uzupełnia skoki z listy
resolve:
    mov r8, [code_buf]
.loop:
    test edi, edi
    jz .done
    lea ecx, [rdi - 1]
    mov edi, [r8 + rcx]
    mov eax, esi
    sub eax, ecx
    sub eax, 4
    mov [r8 + rcx], eax
    jmp .loop
.done:
    ret

; patch_here(ecx=pozycja pola rel32) — skok w przód na bieżącą pozycję
patch_here:
    CODE_POS rax
    sub eax, ecx
    sub eax, 4
    mov r8, [code_buf]
    mov [r8 + rcx], eax
    ret

; ===================== generowanie wartości =====================

; materialize(edi=rodzaj, rsi=wartość) — wartość do rax; zmienia tylko rax
materialize:
    cmp edi, K_REG
    je .ret
    ja err_need_num
    cmp edi, K_VAR
    je .var
    test rsi, rsi
    jnz .nz
    EMIT 0x31, 0xc0                 ; xor eax, eax
.ret:
    ret
.nz:
    movsxd rax, esi
    cmp rax, rsi
    jne .big
    EMIT 0x48, 0xc7, 0xc0           ; mov rax, imm32
    EMITD esi
    ret
.big:
    EMIT 0x48, 0xb8                 ; mov rax, imm64
    EMITQ rsi
    ret
.var:
    EMIT 0x49, 0x8b, 0x87           ; mov rax, [r15 + disp32]
    push rcx
    mov ecx, esi
    shl ecx, 4
    add ecx, D_VARS
    EMITD ecx
    pop rcx
    ret

; load_rcx(edi=rodzaj K_CONST/K_VAR, rsi=wartość) — wartość do rcx; zmienia rax
load_rcx:
    cmp edi, K_REG
    ja err_need_num
    cmp edi, K_VAR
    je .var
    movsxd rax, esi
    cmp rax, rsi
    jne .big
    EMIT 0x48, 0xc7, 0xc1           ; mov rcx, imm32
    EMITD esi
    ret
.big:
    EMIT 0x48, 0xb9                 ; mov rcx, imm64
    EMITQ rsi
    ret
.var:
    EMIT 0x49, 0x8b, 0x8f           ; mov rcx, [r15 + disp32]
    push rcx
    mov ecx, esi
    shl ecx, 4
    add ecx, D_VARS
    EMITD ecx
    pop rcx
    ret

; unpush(r9=pozycja za "push rax" albo -1) — lewy argument wraca do rax:
; gdy od push nic nie wygenerowano, push jest cofany, inaczej pop rax
; (prawy argument był stałą albo zmienną — kod pomiędzy nie zmienia rax)
unpush:
    cmp r9, -1
    je .ret
    cmp r9, [code_buf + 8]
    jne .pop
    dec qword [code_buf + 8]
.ret:
    ret
.pop:
    EMIT 0x58                       ; pop rax
    ret

; load_pair(esi=rodzaj L, r8=wartość L, ecx=rodzaj P, rdx=wartość P, r9=push)
; — kod: L do rax, P do rcx; zmienia rax, rdi, rsi
load_pair:
    cmp esi, K_REG
    jne .l_mem
    cmp ecx, K_REG
    jne .lreg_pmem
    EMIT 0x48, 0x89, 0xc1, 0x58     ; mov rcx, rax / pop rax
    ret
.lreg_pmem:
    call unpush
    mov edi, ecx
    mov rsi, rdx
    jmp load_rcx
.l_mem:
    cmp ecx, K_REG
    jne .both_mem
    EMIT 0x48, 0x89, 0xc1           ; mov rcx, rax
    mov edi, esi
    mov rsi, r8
    jmp materialize
.both_mem:
    mov edi, esi
    mov rsi, r8
    call materialize
    mov edi, ecx
    mov rsi, rdx
    jmp load_rcx

; set_result(edi=warunek) — setcc al / movzx eax, al; zapamiętuje miejsce
; (warunek if/while zamieni je potem na jeden skok warunkowy)
set_result:
    CODE_POS rax
    mov [last_set_pos], eax
    mov [last_set_cc], edi
    mov eax, 3
    call code_need
    mov byte [rax], 0x0f
    lea ecx, [rdi + 0x90]
    mov [rax + 1], cl
    mov byte [rax + 2], 0xc0
    EMIT 0x0f, 0xb6, 0xc0
    CODE_POS rax
    mov [last_set_end], eax
    ret

; fold(edi=operator, r8=a, rdx=b) -> CF=0: rax = a op b; CF=1: nie da się
; policzyć bez błędu (wtedy kod liczy to w trakcie i zgłasza błąd)
fold:
    mov rax, r8
    cmp edi, OP_ADD
    je .add
    cmp edi, OP_SUB
    je .sub
    cmp edi, OP_MUL
    je .mul
    cmp edi, OP_DIV
    jae .div
    ; porównanie
    lea rcx, [cc_tab]
    movzx ecx, byte [rcx + rdi]
    xor eax, eax
    cmp ecx, 4
    je .eq
    cmp ecx, 5
    je .ne
    cmp ecx, 0x0c
    je .lt
    cmp ecx, 0x0e
    je .le
    cmp ecx, 0x0f
    je .gt
    cmp r8, rdx
    setge al
    clc
    ret
.eq: cmp r8, rdx
    sete al
    clc
    ret
.ne: cmp r8, rdx
    setne al
    clc
    ret
.lt: cmp r8, rdx
    setl al
    clc
    ret
.le: cmp r8, rdx
    setle al
    clc
    ret
.gt: cmp r8, rdx
    setg al
    clc
    ret
.add:
    add rax, rdx
    jo .fail
    clc
    ret
.sub:
    sub rax, rdx
    jo .fail
    clc
    ret
.mul:
    imul rax, rdx
    jo .fail
    clc
    ret
.div:
    test rdx, rdx
    jz .fail
    cmp rdx, -1
    je .m1
    mov rcx, rdx
    cqo
    idiv rcx
    cmp edi, OP_MOD
    jne .ok
    mov rax, rdx
.ok:
    clc
    ret
.m1:
    cmp edi, OP_MOD
    je .zero
    neg rax
    jo .fail
    clc
    ret
.zero:
    xor eax, eax
    clc
    ret
.fail:
    stc
    ret

; magic(rdi=dzielnik d, |d| >= 2) -> rax = magiczny mnożnik M, ecx = przesunięcie s
; (Hacker's Delight, rys. 10-1, wersja 64-bitowa)
magic:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r8, rdi
    mov r9, rdi
    neg r9
    test rdi, rdi
    cmovns r9, rdi                  ; r9 = |d| (bez znaku)
    mov r10, 1 << 63
    mov rax, rdi
    shr rax, 63
    add rax, r10                    ; t = 2^63 + (d < 0)
    mov r11, rax
    xor edx, edx
    div r9
    mov r12, r11
    sub r12, 1
    sub r12, rdx                    ; anc = t - 1 - t % |d|
    mov rax, r10
    xor edx, edx
    div r12
    mov r13, rax                    ; q1 = 2^63 / anc
    mov r14, rdx                    ; r1
    mov rax, r10
    xor edx, edx
    div r9
    mov r15, rax                    ; q2 = 2^63 / |d|
    mov rbx, rdx                    ; r2
    mov ebp, 63                     ; p
.loop:
    inc ebp
    add r13, r13
    add r14, r14
    cmp r14, r12
    jb .a
    inc r13
    sub r14, r12
.a:
    add r15, r15
    add rbx, rbx
    cmp rbx, r9
    jb .b
    inc r15
    sub rbx, r9
.b:
    mov rax, r9
    sub rax, rbx                    ; delta = |d| - r2
    cmp r13, rax
    jb .loop
    jne .done
    test r14, r14
    jz .loop
.done:
    lea rax, [r15 + 1]
    test r8, r8
    jns .pos
    neg rax
.pos:
    lea ecx, [rbp - 64]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; gen_binop(edi=operator, esi=rodzaj L, r8=wartość L, ecx=rodzaj P,
;           rdx=wartość P, r9=pozycja za "push rax" albo -1)
; -> eax = rodzaj wyniku, rdx = wartość (dla + - * / % i porównań)
gen_binop:
    push rbx
    push rbp
    push r14
    push r15
    mov ebx, edi
    cmp esi, K_CONST
    jne .no_fold
    cmp ecx, K_CONST
    jne .no_fold
    push rcx
    push rdx
    call fold
    pop rdx
    pop rcx
    jc .no_fold
    mov rdx, rax
    mov eax, K_CONST
    jmp .ret
.no_fold:
    cmp ebx, OP_DIV
    jae .divmod
    ; L do rax, drugi argument X = (r14d rodzaj: K_CONST/K_VAR/K_REG = rcx, r15 wartość)
    cmp esi, K_REG
    jne .l_mem
    cmp ecx, K_REG
    jne .lreg_pmem
    EMIT 0x48, 0x89, 0xc1, 0x58     ; mov rcx, rax / pop rax
    mov r14d, K_REG
    jmp .emit
.lreg_pmem:
    call unpush
    mov r14d, ecx
    mov r15, rdx
    jmp .emit
.l_mem:
    cmp ecx, K_REG
    jne .both_mem
    cmp ebx, OP_ADD
    je .swap
    cmp ebx, OP_MUL
    je .swap
    EMIT 0x48, 0x89, 0xc1           ; mov rcx, rax
    mov edi, esi
    mov rsi, r8
    call materialize
    mov r14d, K_REG
    jmp .emit
.swap:                              ; + i * są przemienne: rax = P, X = L
    mov r14d, esi
    mov r15, r8
    jmp .emit
.both_mem:
    mov r14d, ecx
    mov r15, rdx
    mov edi, esi
    mov rsi, r8
    call materialize
.emit:
    ; duża stała jako drugi argument — najpierw do rcx
    cmp r14d, K_CONST
    jne .form
    movsxd rax, r15d
    cmp rax, r15
    je .form
    mov edi, K_CONST
    mov rsi, r15
    call load_rcx
    mov r14d, K_REG
.form:
    ; ebp = numer wiersza w tablicy postaci: 0 add, 1 sub, 2 imul, 3 cmp
    mov ebp, 3
    cmp ebx, OP_ADD
    jb .have_form
    mov ebp, ebx
    sub ebp, OP_ADD
.have_form:
    cmp r14d, K_CONST
    je .f_imm
    cmp r14d, K_VAR
    je .f_mem
    ; rax op rcx
    cmp ebp, 0
    jne .r1
    EMIT 0x48, 0x01, 0xc8
    jmp .after
.r1: cmp ebp, 1
    jne .r2
    EMIT 0x48, 0x29, 0xc8
    jmp .after
.r2: cmp ebp, 2
    jne .r3
    EMIT 0x48, 0x0f, 0xaf, 0xc1
    jmp .after
.r3: EMIT 0x48, 0x39, 0xc8
    jmp .after
.f_imm:
    cmp ebp, 0
    jne .i1
    EMIT 0x48, 0x05
    jmp .imm32
.i1: cmp ebp, 1
    jne .i2
    EMIT 0x48, 0x2d
    jmp .imm32
.i2: cmp ebp, 2
    jne .i3
    EMIT 0x48, 0x69, 0xc0
    jmp .imm32
.i3: EMIT 0x48, 0x3d
.imm32:
    EMITD r15d
    jmp .after
.f_mem:
    cmp ebp, 0
    jne .m1
    EMIT 0x49, 0x03, 0x87
    jmp .disp
.m1: cmp ebp, 1
    jne .m2
    EMIT 0x49, 0x2b, 0x87
    jmp .disp
.m2: cmp ebp, 2
    jne .m3
    EMIT 0x49, 0x0f, 0xaf, 0x87
    jmp .disp
.m3: EMIT 0x49, 0x3b, 0x87
.disp:
    mov ecx, r15d
    shl ecx, 4
    add ecx, D_VARS
    EMITD ecx
.after:
    cmp ebp, 3
    je .compare
    call emit_jo_ovf
    mov eax, K_REG
    jmp .ret
.compare:
    lea rax, [cc_tab]
    movzx edi, byte [rax + rbx]
    call set_result
    mov eax, K_REG
    jmp .ret

.divmod:
    cmp ecx, K_CONST
    jne .div_gen
    ; dzielnik znany
    mov r15, rdx
    cmp esi, K_REG
    jne .dl_mem
    call unpush
    jmp .dl_done
.dl_mem:
    mov edi, esi
    mov rsi, r8
    call materialize
.dl_done:
    test r15, r15
    jnz .d_nz
    EMIT 0xe9                       ; zawsze dzielenie przez zero
    call div0_stub
    mov esi, eax
    mov edi, S_COLD
    call emit_rel
    mov eax, K_REG
    jmp .ret
.d_nz:
    cmp r15, -1
    jne .d_plain
    cmp ebx, OP_MOD
    je .d_m1_mod
    EMIT 0x48, 0xf7, 0xd8           ; neg rax
    call emit_jo_ovf
    mov eax, K_REG
    jmp .ret
.d_m1_mod:
    EMIT 0x31, 0xc0                 ; x % -1 = 0
    mov eax, K_REG
    jmp .ret
.d_plain:
    cmp r15, 1
    jne .d_magic
    cmp ebx, OP_MOD                 ; x / 1 = x, x % 1 = 0
    jne .d_done
    EMIT 0x31, 0xc0
    jmp .d_done
.d_magic:
    ; dzielenie przez stałą bez idiv: mnożenie przez "magiczną" liczbę
    ; (Hacker's Delight, 10-1): q = hi(n * M) [+/- n] >> s, + 1 gdy ujemne
    mov rdi, r15
    call magic
    mov r14, rax                    ; M
    mov ebp, ecx                    ; s
    EMIT 0x48, 0x89, 0xc1, 0x48, 0xba   ; mov rcx, rax / mov rdx, M
    EMITQ r14
    EMIT 0x48, 0xf7, 0xea           ; imul rdx
    test r15, r15
    js .d_neg
    test r14, r14
    jns .d_shift
    EMIT 0x48, 0x01, 0xca           ; add rdx, rcx
    jmp .d_shift
.d_neg:
    test r14, r14
    js .d_shift
    EMIT 0x48, 0x29, 0xca           ; sub rdx, rcx
.d_shift:
    test ebp, ebp
    jz .d_noshift
    EMIT 0x48, 0xc1, 0xfa           ; sar rdx, s
    mov eax, 1
    call code_need
    mov [rax], bpl
.d_noshift:
    ; mov rax, rdx / shr rax, 63 / add rax, rdx
    EMIT 0x48, 0x89, 0xd0, 0x48, 0xc1, 0xe8, 0x3f, 0x48, 0x01, 0xd0
    cmp ebx, OP_MOD
    jne .d_done
    ; reszta: n - q * d
    movsxd rax, r15d
    cmp rax, r15
    jne .d_bigmul
    EMIT 0x48, 0x69, 0xc0           ; imul rax, rax, d
    EMITD r15d
    jmp .d_sub
.d_bigmul:
    EMIT 0x48, 0xba                 ; mov rdx, d / imul rax, rdx
    EMITQ r15
    EMIT 0x48, 0x0f, 0xaf, 0xc2
.d_sub:
    EMIT 0x48, 0x29, 0xc1, 0x48, 0x89, 0xc8     ; sub rcx, rax / mov rax, rcx
.d_done:
    mov eax, K_REG
    jmp .ret
.div_gen:
    call load_pair
    EMIT 0x48, 0x85, 0xc9           ; test rcx, rcx
    call div0_stub
    mov esi, eax
    mov edi, 4                      ; jz
    call emit_jcc_cold
    ; gdy obie liczby mieszczą się w 32 bitach, idiv r32 (dużo szybszy);
    ; dzielnik -1 osobno (INT_MIN / -1 to wyjątek procesora)
    ;     movsxd rdx, eax / cmp rdx, rax / jne .wide
    ;     movsxd rdx, ecx / cmp rdx, rcx / jne .wide
    ;     cmp ecx, -1 / je .m1 / cdq / idiv ecx / movsxd rax, eax|edx / jmp .done
    ; .wide: cmp rcx, -1 / je .m1 / cqo / idiv rcx [/ mov rax, rdx] / jmp .done
    ; .m1:   neg rax / jo błąd   (reszta: xor eax, eax)
    EMIT 0x48, 0x63, 0xd0, 0x48, 0x39, 0xc2, 0x75, 21, 0x48, 0x63, 0xd1, 0x48, 0x39, 0xca, 0x75, 13
    cmp ebx, OP_MOD
    je .g_mod
    EMIT 0x83, 0xf9, 0xff, 0x74, 21, 0x99, 0xf7, 0xf9, 0x48, 0x63, 0xc0, 0xeb, 22
    EMIT 0x48, 0x83, 0xf9, 0xff, 0x74, 7, 0x48, 0x99, 0x48, 0xf7, 0xf9, 0xeb, 9
    EMIT 0x48, 0xf7, 0xd8           ; neg rax
    call emit_jo_ovf
    mov eax, K_REG
    jmp .ret
.g_mod:
    EMIT 0x83, 0xf9, 0xff, 0x74, 24, 0x99, 0xf7, 0xf9, 0x48, 0x63, 0xc2, 0xeb, 18
    EMIT 0x48, 0x83, 0xf9, 0xff, 0x74, 10, 0x48, 0x99, 0x48, 0xf7, 0xf9, 0x48, 0x89, 0xd0, 0xeb, 2
    EMIT 0x31, 0xc0
    mov eax, K_REG
.ret:
    pop r15
    pop r14
    pop rbp
    pop rbx
    ret

; ===================== parser wyrażeń =====================

; ws — pomija spacje i tabulatory (r12 < r13); zmienia al
ws:
    cmp r12, r13
    jae .done
    mov al, [r12]
    cmp al, ' '
    je .skip
    cmp al, 9
    jne .done
.skip:
    inc r12
    jmp ws
.done:
    ret

; at_word(rdi=słowo, esi=długość) -> eax = 1, gdy w r12 stoi dokładnie
; ten identyfikator (dalej nie ma znaku nazwy)
at_word:
    lea rax, [r12 + rsi]
    cmp rax, r13
    ja .no
    xor ecx, ecx
.cmp:
    cmp ecx, esi
    je .end
    mov al, [r12 + rcx]
    cmp al, [rdi + rcx]
    jne .no
    inc ecx
    jmp .cmp
.end:
    lea rax, [r12 + rsi]
    cmp rax, r13
    jae .yes
    movzx eax, byte [rax]
    lea rcx, [ident_tab]
    cmp byte [rcx + rax], 0
    jne .no
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; peek_binop -> eax = operator (0 = brak), ecx = jego długość; kursor bez zmian
peek_binop:
    xor eax, eax
    cmp r12, r13
    jae .ret
    movzx edx, byte [r12]
    xor r8d, r8d                    ; drugi znak (0 = koniec)
    lea rcx, [r12 + 1]
    cmp rcx, r13
    jae .one
    mov r8b, [r12 + 1]
.one:
    mov ecx, 1
    cmp dl, '+'
    je .add
    cmp dl, '-'
    je .sub
    cmp dl, '*'
    je .mul
    cmp dl, '/'
    je .div
    cmp dl, '%'
    je .mod
    cmp dl, '<'
    je .lt
    cmp dl, '>'
    je .gt
    mov ecx, 2
    cmp dl, '='
    je .eq
    cmp dl, '!'
    je .ne
    cmp dl, 'a'
    je .and
    cmp dl, 'o'
    je .or
.ret:
    ret
.add: mov eax, OP_ADD
    ret
.sub: mov eax, OP_SUB
    ret
.mul: mov eax, OP_MUL
    ret
.div: mov eax, OP_DIV
    ret
.mod: mov eax, OP_MOD
    ret
.lt:
    mov eax, OP_LT
    cmp r8b, '='
    jne .ret
    mov eax, OP_LE
    mov ecx, 2
    ret
.gt:
    mov eax, OP_GT
    cmp r8b, '='
    jne .ret
    mov eax, OP_GE
    mov ecx, 2
    ret
.eq:
    cmp r8b, '='
    jne .ret
    mov eax, OP_EQ
    ret
.ne:
    cmp r8b, '='
    jne .ret
    mov eax, OP_NE
    ret
.and:
    lea rdi, [kw_and]
    mov esi, 3
    call at_word
    test eax, eax
    jz .ret
    mov eax, OP_AND
    mov ecx, 3
    ret
.or:
    lea rdi, [kw_or]
    mov esi, 2
    call at_word
    test eax, eax
    jz .ret
    mov eax, OP_OR
    mov ecx, 2
    ret

; expr(edi=najniższy priorytet) -> eax = rodzaj, rdx = wartość
; wspinaczka po priorytetach; rekurencja tylko dla prawych argumentów i nawiasów
expr:
    push rbx
    push rbp
    push r14
    push r15
    mov r14d, edi
    call unary
    mov ebx, eax
    mov rbp, rdx
.loop:
    call ws
    call peek_binop
    test eax, eax
    jz .ret
    lea rdx, [prec_tab]
    movzx edi, byte [rdx + rax]
    cmp edi, r14d
    jb .ret
    add r12, rcx
    cmp eax, OP_AND
    jbe .logic
    cmp eax, OP_GE
    jbe .compare
    ; + - * / %: prawy argument o priorytecie wyższym
    mov r15d, eax
    cmp ebx, K_REG
    ja .text_left
    mov r9, -1
    cmp ebx, K_REG
    jne .nopush
    EMIT 0x50                       ; push rax (lewy argument)
    mov r9, [code_buf + 8]
.nopush:
    push r9
    push r15
    inc edi
    call expr
    pop r15
    pop r9
    mov ecx, eax
    cmp eax, K_REG
    ja .r_text
    mov edi, r15d
    mov esi, ebx
    mov r8, rbp
    call gen_binop
    mov ebx, eax
    mov rbp, rdx
    jmp .loop
.r_text:
    ; liczba + tekst: łączenie (liczba jako tekst)
    cmp r15d, OP_ADD
    jne err_text_op
.cat:
    mov esi, ebx
    mov r8, rbp
    call cat_gen
    mov ebx, eax
    mov rbp, rdx
    jmp .loop
.text_left:
    ; tekst + ...: tylko łączenie
    cmp r15d, OP_ADD
    jne err_text_op
    mov r9, -1
    cmp ebx, K_TREG
    jne .tl_nopush
    EMIT 0x50, 0x52                 ; push rax / push rdx (lewy tekst)
    mov r9, [code_buf + 8]
.tl_nopush:
    push r9
    inc edi
    call expr
    pop r9
    mov ecx, eax
    jmp .cat

.logic:
    ; and / or: lewy argument sprawdzony od razu, prawy liczony tylko w razie potrzeby
    mov r15d, eax
    mov edi, ebx
    mov rsi, rbp
    call materialize
    EMIT 0x48, 0x85, 0xc0, 0x0f     ; test rax, rax / jz albo jnz
    mov eax, 1
    call code_need
    mov byte [rax], 0x84            ; jz (and)
    cmp r15d, OP_AND
    je .l_slot
    mov byte [rax], 0x85            ; jnz (or)
.l_slot:
    EMITD 0
    CODE_POS rax
    sub eax, 4
    push rax                        ; pole rel32 skoku
    push r15
    lea edi, [r15 + 1]              ; prawy argument: priorytet o 1 wyższy
    cmp r15d, OP_AND
    je .l_right
    mov edi, 2
.l_right:
    call expr
    mov edi, eax
    mov rsi, rdx
    call materialize
    pop r15
    pop rcx
    ; test rax, rax / setnz al / movzx eax, al
    EMIT 0x48, 0x85, 0xc0, 0x0f, 0x95, 0xc0, 0x0f, 0xb6, 0xc0
    cmp r15d, OP_AND
    jne .l_or
    EMIT 0xeb, 0x02                 ; jmp .done / .false: xor eax, eax
    call patch_here
    EMIT 0x31, 0xc0
    jmp .l_done
.l_or:
    EMIT 0xeb, 0x05                 ; jmp .done / .true: mov eax, 1
    call patch_here
    EMIT 0xb8, 1, 0, 0, 0
.l_done:
    mov ebx, K_REG
    jmp .loop

.compare:
    cmp ebx, K_REG
    ja .tcompare
    ; łańcuch porównań a < b < c: przy fałszu skok do "wynik 0" (lista na stosie)
    push 0
    mov r15d, eax
.c_step:
    mov r9, -1
    cmp ebx, K_REG
    jne .c_nopush
    EMIT 0x50
    mov r9, [code_buf + 8]
.c_nopush:
    push r9
    push r15
    mov edi, P_CMP + 1
    call expr
    cmp eax, K_REG
    ja err_cmp_mix
    pop r15
    pop r9
    push rax
    push rdx
    push r9
    call ws
    call peek_binop
    pop r9
    pop rdx
    mov r10d, eax                   ; następny operator
    pop rax
    cmp r10d, OP_EQ
    jb .c_last
    cmp r10d, OP_GE
    ja .c_last
    ; kolejne porównanie: L do rax, P do rcx, cmp, przy fałszu skok, P zostaje w rax
    push r10
    push rcx
    mov esi, ebx
    mov r8, rbp
    mov ecx, eax
    call load_pair
    EMIT 0x48, 0x39, 0xc8           ; cmp rax, rcx
    lea rax, [cc_tab]
    movzx edi, byte [rax + r15]
    xor edi, 1
    lea rsi, [rsp + 16]
    call emit_j32
    EMIT 0x48, 0x89, 0xc8           ; mov rax, rcx
    pop rcx
    pop r10
    add r12, rcx
    mov r15d, r10d
    mov ebx, K_REG
    jmp .c_step
.c_last:
    mov ecx, eax
    mov edi, r15d
    mov esi, ebx
    mov r8, rbp
    call gen_binop
    mov ebx, eax
    mov rbp, rdx
    pop rdi                         ; lista skoków "fałsz"
    test edi, edi
    jz .loop
    push rdi
    mov ebx, K_REG
    mov edi, K_REG
    cmp eax, K_CONST                ; ostatnie porównanie złożone — wynik do rax
    jne .c_tail
    mov edi, eax
    mov rsi, rbp
    call materialize
.c_tail:
    EMIT 0xeb, 0x02                 ; jmp .done / .false: xor eax, eax
    pop rdi
    CODE_POS rsi
    call resolve
    EMIT 0x31, 0xc0
    mov dword [last_set_end], -1
    jmp .loop

.tcompare:
    ; tekst == tekst, tekst != tekst (bez łańcuchów)
    mov r15d, eax
    cmp eax, OP_EQ
    je .tc_ok
    cmp eax, OP_NE
    jne err_text_op
.tc_ok:
    mov r9, -1
    cmp ebx, K_TREG
    jne .tc_nopush
    EMIT 0x50, 0x52                 ; push rax / push rdx
    mov r9, [code_buf + 8]
.tc_nopush:
    push r9
    push r15
    mov edi, P_CMP + 1
    call expr
    pop r15
    pop r9
    cmp eax, K_REG
    jbe err_cmp_mix
    mov ecx, eax
    mov edi, r15d
    mov esi, ebx
    mov r8, rbp
    call tcmp_gen
    mov ebx, eax
    mov rbp, rdx
    call ws
    call peek_binop
    cmp eax, OP_EQ
    jb .loop
    cmp eax, OP_GE
    jbe err_text_chain
    jmp .loop

.ret:
    mov eax, ebx
    mov rdx, rbp
    pop r15
    pop r14
    pop rbp
    pop rbx
    ret

; unary(edi=najniższy priorytet) -> eax, rdx
; not (gdy dozwolone): ciąg słów not, potem porównanie; - i +: parzystość minusów
unary:
    push rbx
    push rbp
    mov ebx, edi
    call ws
    cmp ebx, P_NOT
    ja .minus
    lea rdi, [kw_not]
    mov esi, 3
    call at_word
    test eax, eax
    jz .minus
    xor ebp, ebp
.not_loop:
    add r12, 3
    xor ebp, 1
    call ws
    lea rdi, [kw_not]
    mov esi, 3
    call at_word
    test eax, eax
    jnz .not_loop
    mov edi, P_CMP
    call expr
    cmp eax, K_CONST
    jne .not_gen
    xor ecx, ecx
    test rdx, rdx
    setnz cl                        ; parzyście wiele not: x != 0
    xor ecx, ebp                    ; nieparzyście: x == 0
    mov edx, ecx
    jmp .ret
.not_gen:
    mov edi, eax
    mov rsi, rdx
    call materialize
    EMIT 0x48, 0x85, 0xc0           ; test rax, rax
    mov edi, 5                      ; setne
    sub edi, ebp                    ; nieparzyście: sete
    call set_result
    mov eax, K_REG
    jmp .ret
.minus:
    xor ebp, ebp
.m_loop:
    call ws
    cmp r12, r13
    jae .prim
    mov al, [r12]
    cmp al, '-'
    jne .plus
    xor ebp, 1
    inc r12
    jmp .m_loop
.plus:
    cmp al, '+'
    jne .prim
    inc r12
    jmp .m_loop
.prim:
    call primary
    test ebp, ebp
    jz .ret
    cmp eax, K_CONST
    jne .neg_gen
    mov rcx, rdx
    neg rcx
    jo .neg_gen                     ; -INT64_MIN: błąd w trakcie
    mov rdx, rcx
    jmp .ret
.neg_gen:
    mov edi, eax
    mov rsi, rdx
    call materialize
    EMIT 0x48, 0xf7, 0xd8           ; neg rax
    call emit_jo_ovf
    mov eax, K_REG
.ret:
    pop rbp
    pop rbx
    ret

; primary -> eax, rdx: prosty element i ewentualne indeksy tekstu t[i], t[a:b]
primary:
    call primary0
.post:
    push rax
    call ws
    pop rax
    AT '['
    jne .ret
    cmp eax, K_REG
    jbe err_index_int
    call index_gen
    jmp .post
.ret:
    ret

; primary0 -> eax, rdx: liczba, napis, zmienna, funkcja albo wyrażenie w nawiasie
primary0:
    cmp r12, r13
    jae err_incomplete
    movzx eax, byte [r12]
    cmp al, '('
    je .paren
    cmp al, '"'
    je .text
    cmp al, "'"
    je .char
    lea ecx, [rax - '0']
    cmp ecx, 9
    jbe .number
    lea rcx, [ident_tab]
    cmp byte [rcx + rax], 0
    je err_unexpected
    jmp .name
.paren:
    mov rax, [paren_depth]
    cmp rax, [max_depth]
    jae err_too_deep
    cmp rsp, [hard_floor]
    jb err_too_deep
    inc qword [paren_depth]
    inc r12
    xor edi, edi
    call expr
    push rax
    call ws
    pop rax
    cmp r12, r13
    jae err_rparen_e
    cmp byte [r12], ')'
    jne err_rparen_e
    inc r12
    dec qword [paren_depth]
    ret
.number:
    xor edx, edx
.digit:
    imul rdx, rdx, 10
    jo err_big
    add rdx, rcx
    jo err_big
    inc r12
    cmp r12, r13
    jae .num_done
    movzx ecx, byte [r12]
    sub ecx, '0'
    cmp ecx, 9
    jbe .digit
.num_done:
    mov eax, K_CONST
    ret
.text:
    ; napis w wyrażeniu: stała tekstowa
    push rbx
    push rbp
    inc r12
    call scan_string
    xor ecx, ecx
    call text_const
    shl rdx, 32
    or rdx, rax
    mov eax, K_TLIT
    pop rbp
    pop rbx
    ret
.name:
    push rbx
    mov rbx, r12
    call skip_ident
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    call kw_id
    cmp eax, KW_INPUT
    jae .func
    cmp eax, KW_AND
    jae .kw_bad
    ; len( / inputtext(: funkcje wbudowane (nazwa przed nawiasem)
    mov rcx, r12
    sub rcx, rbx
    push r12
    call ws
    AT '('
    pop r12
    jne .var
    cmp ecx, 3
    jne .not_len
    mov ax, [rbx]
    cmp ax, 'le'
    jne .not_len
    cmp byte [rbx + 2], 'n'
    je .len
.not_len:
    cmp ecx, 9
    jne .var
    mov rax, [rbx]
    cmp rax, [fn_inputtext]
    jne .var
    cmp byte [rbx + 8], 't'
    je .inputtext
.var:
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    call lookup
    cmp eax, -1
    je .unknown
    lea rcx, [var_assigned]
    cmp byte [rcx + rax], 0
    je .unknown
    mov ebx, eax
    mov edi, eax
    call emit_var_check
    mov eax, K_VAR
    lea rcx, [var_type]
    cmp byte [rcx + rbx], 2
    jne .var_kind
    mov eax, K_TVAR
.var_kind:
    mov edx, ebx
    pop rbx
    ret
.inputtext:
    call ws
    inc r12                         ; '('
    call ws
    AT ')'
    jne err_func
    inc r12
    mov edi, RT_INPUTTEXT
    call emit_call_rt
    mov qword [stmt_tmp], 1
    mov eax, K_TREG
    pop rbx
    ret
.len:
    ; len(tekst) -> liczba znaków
    call ws
    mov rax, [paren_depth]
    cmp rax, [max_depth]
    jae err_too_deep
    cmp rsp, [hard_floor]
    jb err_too_deep
    inc qword [paren_depth]
    inc r12                         ; '('
    xor edi, edi
    call expr
    push rax
    call ws
    pop rax
    AT ')'
    jne err_rparen_e
    inc r12
    dec qword [paren_depth]
    cmp eax, K_REG
    jbe err_len_text
    cmp eax, K_TLIT
    jne .len_gen
    mov rcx, rdx                    ; stała: liczba znaków od razu
    shr rcx, 32
    mov esi, edx
    add rsi, [const_buf]
    call utf8_count
    mov rdx, rax
    mov eax, K_CONST
    pop rbx
    ret
.len_gen:
    mov edi, eax
    mov rsi, rdx
    call tmaterialize
    mov edi, RT_LEN
    call emit_call_rt
    mov eax, K_REG
    pop rbx
    ret
.kw_bad:
    mov r12, rbx
    jmp err_unexpected
.func:
    ; funkcja wbudowana bez argumentów: nazwa ( )
    mov ebx, eax
    call ws
    AT '('
    jne err_func
    inc r12
    call ws
    AT ')'
    jne err_func
    inc r12
    cmp ebx, KW_INPUTOK
    jae .flag
    mov edi, RT_INPUT
    cmp ebx, KW_INPUT
    je .call
    mov edi, RT_INPUTCHAR
.call:
    call emit_call_rt
    jmp .func_done
.flag:
    EMIT 0x49, 0x8b, 0x87           ; mov rax, [r15 + D_INOK / D_EOF]
    mov ecx, D_INOK
    cmp ebx, KW_INPUTOK
    je .flag_off
    mov ecx, D_EOF
.flag_off:
    EMITD ecx
.func_done:
    mov eax, K_REG
    pop rbx
    ret
.char:
    ; literał znakowy: 'c' albo '\n' '\t' '\\' '\'' — wartość to kod znaku
    lea rax, [r12 + 2]
    cmp rax, r13
    jae err_char_lit
    movzx edx, byte [r12 + 1]
    cmp dl, '\'
    je .char_esc
    cmp dl, "'"
    je err_char_lit
    cmp dl, ' '
    jb err_char_lit
    cmp dl, '~'
    ja err_char_lit
    cmp byte [r12 + 2], "'"
    jne err_char_lit
    add r12, 3
    mov eax, K_CONST
    ret
.char_esc:
    lea rax, [r12 + 3]
    cmp rax, r13
    jae err_char_lit
    cmp byte [r12 + 3], "'"
    jne err_char_lit
    movzx eax, byte [r12 + 2]
    mov edx, 10
    cmp al, 'n'
    je .char_ok
    mov edx, 9
    cmp al, 't'
    je .char_ok
    mov edx, eax
    cmp al, '\'
    je .char_ok
    cmp al, "'"
    jne err_char_lit
.char_ok:
    add r12, 4
    mov eax, K_CONST
    ret
.unknown:
    mov rdx, rbx
    mov rcx, r12
    sub rcx, rbx
    jmp die_unknown_var

; die_unknown_var(rdx=nazwa, ecx=długość) — "nieznana zmienna 'x'"
die_unknown_var:
    lea rdi, [msg_unk1]
    mov esi, msg_unk1_len
    lea r8, [msg_q]
    mov r9d, 1
    jmp die_name

; emit_var_check(edi=numer) — gdy zmienna może nie mieć wartości:
; cmp byte [r15 + flaga], 0 / je błąd
emit_var_check:
    lea rax, [var_proven]
    cmp byte [rax + rdi], 0
    jne .ret
    push rdi
    push rsi
    mov esi, edi
    mov edi, RT_DIE_VAR
    call make_stub
    mov esi, eax
    mov edi, [rsp + 8]
    EMIT 0x41, 0x80, 0xbf           ; cmp byte [r15 + disp32], 0
    shl edi, 4
    add edi, D_VARS + 8
    EMITD edi
    EMIT 0
    mov edi, 4                      ; je
    call emit_jcc_cold
    pop rsi
    pop rdi
.ret:
    ret

; skip_ident — przesuwa r12 za znaki nazwy (do r13)
skip_ident:
    lea rcx, [ident_tab]
.loop:
    cmp r12, r13
    jae .done
    movzx eax, byte [r12]
    cmp byte [rcx + rax], 0
    je .done
    inc r12
    jmp .loop
.done:
    ret

; kw_id(rdi=nazwa, rsi=długość) -> eax = KW_* albo 0
kw_id:
    lea r8, [kw_tab]
    mov eax, 1
.next:
    movzx ecx, byte [r8]
    test ecx, ecx
    jz .none
    cmp rcx, rsi
    jne .skip
    xor edx, edx
.cmp:
    cmp edx, ecx
    je .found
    mov r9b, [rdi + rdx]
    cmp r9b, [r8 + 1 + rdx]
    jne .skip
    inc edx
    jmp .cmp
.skip:
    lea r8, [r8 + rcx + 1]
    inc eax
    jmp .next
.none:
    xor eax, eax
.found:
    ret

; lookup(rdi=nazwa, rsi=długość) -> eax = numer zmiennej albo -1,
; ecx = miejsce w tablicy (wolne, gdy nie znaleziono)
lookup:
    push rbx
    push r10
    push r11
    mov rax, 0xcbf29ce484222325     ; FNV-1a
    mov r10, 0x100000001b3
    xor ecx, ecx
.hash:
    cmp rcx, rsi
    jae .hashed
    movzx edx, byte [rdi + rcx]
    xor rax, rdx
    imul rax, r10
    inc rcx
    jmp .hash
.hashed:
    mov ecx, eax
    and ecx, HSLOTS - 1
    lea r11, [htab]
.probe:
    mov ebx, ecx
    shl rbx, 4
    mov eax, [r11 + rbx + 12]
    test eax, eax
    jz .missing
    cmp [r11 + rbx + 8], esi
    jne .next
    mov r10, [r11 + rbx]
    xor edx, edx
.cmp:
    cmp rdx, rsi
    je .found
    mov al, [rdi + rdx]
    cmp al, [r10 + rdx]
    jne .next
    inc rdx
    jmp .cmp
.found:
    mov eax, [r11 + rbx + 12]
    dec eax
    jmp .ret
.next:
    inc ecx
    and ecx, HSLOTS - 1
    jmp .probe
.missing:
    mov eax, -1
.ret:
    pop r11
    pop r10
    pop rbx
    ret

; ===================== teksty =====================

; text_const(rbx=początek, rbp=koniec treści napisu, ecx=1: dopisz '\n')
; -> rax = przesunięcie w stałych, rdx = długość (sekwencje ucieczki rozwinięte)
text_const:
    push r10
    push r9
    mov r10d, ecx
    mov r9, [const_buf + 8]
    mov rax, rbp
    sub rax, rbx
    inc rax
    call const_need
    mov rdi, rax
    mov rsi, rbx
.loop:
    cmp rsi, rbp
    jae .end
    mov al, [rsi]
    inc rsi
    cmp al, '\'
    jne .put
    mov al, [rsi]
    inc rsi
    cmp al, 'n'
    je .n
    cmp al, 't'
    je .t
    cmp al, '\'
    je .put
    cmp al, '"'
    je .put
    jmp err_escape
.n: mov al, 10
    jmp .put
.t: mov al, 9
.put:
    mov [rdi], al
    inc rdi
    jmp .loop
.end:
    test r10d, r10d
    jz .nonl
    mov byte [rdi], 10
    inc rdi
.nonl:
    sub rdi, [const_buf]
    mov [const_buf + 8], rdi        ; długość po rozwinięciu
    mov rdx, rdi
    sub rdx, r9
    mov rax, r9
    pop r9
    pop r10
    ret

; tmaterialize(edi=rodzaj tekstu, rsi=wartość) — kod: tekst do rax, rdx;
; zmienia tylko rax
tmaterialize:
    cmp edi, K_TREG
    je .ret
    cmp edi, K_TLIT
    je .lit
    EMIT 0x49, 0x8b, 0x87           ; mov rax, [r15 + disp32]
    push rcx
    mov ecx, esi
    shl ecx, 4
    add ecx, D_VARS
    EMITD ecx
    pop rcx
    EMIT 0x48, 0x8b, 0x50, 0x08     ; mov rdx, [rax + 8]
    EMIT 0x48, 0x83, 0xc0, 0x10     ; add rax, 16
.ret:
    ret
.lit:
    push rdi
    push rsi
    EMIT 0x48, 0x8d, 0x05           ; lea rax, [rip + napis]
    mov edi, S_CONST
    call emit_rel
    EMIT 0xba                       ; mov edx, długość
    mov rsi, [rsp]
    shr rsi, 32
    EMITD esi
    pop rsi
    pop rdi
    ret

; tload2(edi=rodzaj tekstu, rsi=wartość) — kod: tekst do rcx, r8; zmienia tylko rax
tload2:
    cmp edi, K_TREG
    je .reg
    cmp edi, K_TLIT
    je .lit
    EMIT 0x49, 0x8b, 0x8f           ; mov rcx, [r15 + disp32]
    push rcx
    mov ecx, esi
    shl ecx, 4
    add ecx, D_VARS
    EMITD ecx
    pop rcx
    EMIT 0x4c, 0x8b, 0x41, 0x08     ; mov r8, [rcx + 8]
    EMIT 0x48, 0x83, 0xc1, 0x10     ; add rcx, 16
    ret
.reg:
    EMIT 0x48, 0x89, 0xc1           ; mov rcx, rax
    EMIT 0x49, 0x89, 0xd0           ; mov r8, rdx
    ret
.lit:
    push rdi
    push rsi
    EMIT 0x48, 0x8d, 0x0d           ; lea rcx, [rip + napis]
    mov edi, S_CONST
    call emit_rel
    EMIT 0x41, 0xb8                 ; mov r8d, długość
    mov rsi, [rsp]
    shr rsi, 32
    EMITD esi
    pop rsi
    pop rdi
    ret

; to_text(edi=rodzaj, rsi=wartość) -> eax, rdx: tekst (liczba zamieniona na
; zapis dziesiętny: stała podczas kompilacji, inaczej w trakcie — rt_int2text,
; które zachowuje rcx i r8)
to_text:
    mov eax, edi
    mov rdx, rsi
    cmp edi, K_REG
    ja .ret
    cmp edi, K_CONST
    je .const
    call materialize
    mov edi, RT_INT2TEXT
    call emit_call_rt
    mov qword [stmt_tmp], 1
    mov eax, K_TREG
.ret:
    ret
.const:
    push rbx
    push rcx
    push r8
    push r9
    push r10
    sub rsp, 32
    mov rdi, rsi
    lea rsi, [rsp + 32]
    call fmt_int                    ; -> rax = początek cyfr
    lea rbx, [rsp + 32]
    sub rbx, rax                    ; długość
    push rax
    mov r9, [const_buf + 8]
    mov rax, rbx
    call const_need
    mov rdi, rax
    pop rsi
    mov rcx, rbx
    rep movsb
    add rsp, 32
    mov rdx, rbx
    shl rdx, 32
    or rdx, r9
    mov eax, K_TLIT
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

; lit_concat(rsi=stała A, rdx=stała B) -> rdx = stała A + B
lit_concat:
    push rbx
    push rcx
    push r8
    push r9
    mov r8, rsi
    mov r9, rdx
    mov rbx, r8
    shr rbx, 32
    mov rcx, r9
    shr rcx, 32
    add rbx, rcx                    ; długość wyniku
    mov rcx, [const_buf + 8]        ; przesunięcie wyniku
    push rcx
    mov rax, rbx
    call const_need                 ; (bufor mógł się przenieść)
    mov rdi, rax
    mov rsi, [const_buf]
    mov eax, r8d
    add rsi, rax
    mov rcx, r8
    shr rcx, 32
    rep movsb
    mov rsi, [const_buf]
    mov eax, r9d
    add rsi, rax
    mov rcx, r9
    shr rcx, 32
    rep movsb
    pop rdx
    shl rbx, 32
    or rdx, rbx
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

; lit_like(edi=rodzaj) -> ZF=1 dla stałej (K_TLIT albo K_CONST)
%macro LIT_LIKE 1
    cmp %1, K_TLIT
    je %%done
    cmp %1, K_CONST
%%done:
%endmacro

; cat_gen(esi=rodzaj L, r8=wartość L, ecx=rodzaj P, rdx=wartość P,
;         r9=pozycja za push lewego argumentu albo -1) -> eax, rdx: L + P
; Lewy argument w rejestrach (K_TREG, K_REG) został wcześniej odłożony na stos
; (push rax / push rdx dla tekstu, push rax dla liczby).
cat_gen:
    push rbx
    push rbp
    push r14
    push r15
    mov ebx, esi
    mov rbp, r8
    mov r14d, ecx
    mov r15, rdx
    LIT_LIKE ebx
    jne .run
    LIT_LIKE r14d
    jne .run
    ; obie strony stałe: łączenie podczas kompilacji
    mov edi, r14d
    mov rsi, r15
    call to_text
    mov r15, rdx
    mov edi, ebx
    mov rsi, rbp
    call to_text
    mov rsi, rdx
    mov rdx, r15
    call lit_concat
    mov eax, K_TLIT
    jmp .ret
.run:
    cmp ebx, K_REG
    jbe .run_any
    cmp r14d, K_REG                 ; tekst + liczba (nie stała): cyfry
    je .ci_reg                      ; dopisywane od razu (rt_cat_int)
    cmp r14d, K_VAR
    je .ci_var
.run_any:
    cmp ebx, K_TREG
    je .l_treg
    cmp ebx, K_REG
    je .l_reg
    ; L w pamięci albo stała: P do rcx, r8, potem L do rax, rdx
    mov edi, r14d
    mov rsi, r15
    call to_text
    mov edi, eax
    mov rsi, rdx
    call tload2
    mov edi, ebx
    mov rsi, rbp
    call to_text
    mov edi, eax
    mov rsi, rdx
    call tmaterialize
    jmp .cat
.l_treg:
    cmp r14d, K_TLIT
    je .t_undo
    cmp r14d, K_TVAR
    je .t_undo
    cmp r14d, K_CONST
    jne .t_pop
.t_undo:
    cmp r9, [code_buf + 8]
    jne .t_pop
    sub qword [code_buf + 8], 2     ; P nie zmienił rejestrów: bez push/pop
    mov edi, r14d
    mov rsi, r15
    call to_text
    mov edi, eax
    mov rsi, rdx
    call tload2
    jmp .cat
.t_pop:
    call .right_regs
    EMIT 0x5a, 0x58                 ; pop rdx / pop rax
    jmp .cat
.l_reg:
    cmp r14d, K_TLIT
    je .r_undo
    cmp r14d, K_TVAR
    je .r_undo
    cmp r14d, K_CONST
    jne .r_pop
.r_undo:
    cmp r9, [code_buf + 8]
    jne .r_pop
    dec qword [code_buf + 8]        ; liczba L dalej w rax
    mov edi, RT_INT2TEXT
    call emit_call_rt
    mov edi, r14d
    mov rsi, r15
    call to_text
    mov edi, eax
    mov rsi, rdx
    call tload2
    jmp .cat
.r_pop:
    call .right_regs
    EMIT 0x58                       ; pop rax (liczba L)
    mov edi, RT_INT2TEXT
    call emit_call_rt
.cat:
    mov edi, RT_CAT
.call:
    call emit_call_rt
    mov qword [stmt_tmp], 1
    mov eax, K_TREG
.ret:
    pop r15
    pop r14
    pop rbp
    pop rbx
    ret
.ci_reg:
    EMIT 0x48, 0x89, 0xc1           ; mov rcx, rax (liczba)
    cmp ebx, K_TREG
    jne .ci_lmem
    EMIT 0x5a, 0x58                 ; pop rdx / pop rax
    jmp .ci_call
.ci_var:
    cmp ebx, K_TREG
    jne .ci_var_mem
    cmp r9, [code_buf + 8]
    jne .ci_var_pop
    sub qword [code_buf + 8], 2     ; zmienna nie zmienia rejestrów: bez push/pop
    mov edi, K_VAR
    mov rsi, r15
    call load_rcx
    jmp .ci_call
.ci_var_pop:
    mov edi, K_VAR
    mov rsi, r15
    call load_rcx
    EMIT 0x5a, 0x58                 ; pop rdx / pop rax
    jmp .ci_call
.ci_var_mem:
    mov edi, K_VAR
    mov rsi, r15
    call load_rcx
.ci_lmem:
    mov edi, ebx
    mov rsi, rbp
    call tmaterialize
.ci_call:
    mov edi, RT_CATINT
    jmp .call
; P jako tekst do rcx, r8 przez rax, rdx (L czeka na stosie)
.right_regs:
    mov edi, r14d
    mov rsi, r15
    call to_text
    mov edi, eax
    mov rsi, rdx
    call tmaterialize
    EMIT 0x48, 0x89, 0xc1           ; mov rcx, rax
    EMIT 0x49, 0x89, 0xd0           ; mov r8, rdx
    ret

; tcmp_gen(edi=OP_EQ/OP_NE, esi=rodzaj L, r8=wartość L, ecx=rodzaj P,
;          rdx=wartość P, r9=pozycja za push L albo -1) -> eax, rdx: liczba 1/0
tcmp_gen:
    push rbx
    push rbp
    push r14
    push r15
    push rdi
    mov ebx, esi
    mov rbp, r8
    mov r14d, ecx
    mov r15, rdx
    cmp ebx, K_TLIT
    jne .run
    cmp r14d, K_TLIT
    jne .run
    ; dwie stałe: wynik podczas kompilacji
    xor edx, edx
    mov rcx, rbp
    shr rcx, 32
    mov rax, r15
    shr rax, 32
    cmp rcx, rax
    jne .folded
    mov rsi, [const_buf]
    mov rdi, rsi
    mov eax, ebp
    add rsi, rax
    mov eax, r15d
    add rdi, rax
    mov edx, 1
    test rcx, rcx
    jz .folded
    repe cmpsb
    je .folded
    xor edx, edx
.folded:
    pop rdi
    cmp edi, OP_NE
    jne .f_ok
    xor edx, 1
.f_ok:
    mov eax, K_CONST
    jmp .ret
.run:
    cmp ebx, K_TREG
    jne .l_mem
    cmp r14d, K_TREG
    je .pop
    cmp r9, [code_buf + 8]
    jne .pop
    sub qword [code_buf + 8], 2     ; P nie zmienił rejestrów: bez push/pop
    mov edi, r14d
    mov rsi, r15
    call tload2
    jmp .call
.pop:
    mov edi, r14d
    mov rsi, r15
    call tmaterialize
    EMIT 0x48, 0x89, 0xc1           ; mov rcx, rax
    EMIT 0x49, 0x89, 0xd0           ; mov r8, rdx
    EMIT 0x5a, 0x58                 ; pop rdx / pop rax
    jmp .call
.l_mem:
    mov edi, r14d
    mov rsi, r15
    call tload2
    mov edi, ebx
    mov rsi, rbp
    call tmaterialize
.call:
    mov edi, RT_STREQ
    call emit_call_rt
    pop rdi
    cmp edi, OP_NE
    jne .r_ok
    EMIT 0x83, 0xf0, 0x01           ; xor eax, 1
.r_ok:
    mov eax, K_REG
.ret:
    pop r15
    pop r14
    pop rbp
    pop rbx
    ret

; tmp_done — koniec wyrażenia, które użyło obszaru tymczasowego: kod czyści
; obszar (rt_tmp_reset zachowuje rax); zmienia rax, rsi, rdi
tmp_done:
    cmp qword [stmt_tmp], 0
    je .ret
    mov qword [stmt_tmp], 0
    mov edi, RT_TMPRESET
    jmp emit_call_rt
.ret:
    ret

; index_gen(eax=rodzaj tekstu, rdx=wartość; kursor na '[') -> eax, rdx:
; t[i] (jeden znak) albo t[a:b], t[:b], t[a:] (wycinek)
index_gen:
    push rbx
    push rbp
    push r14
    push r15
    mov ebx, eax
    mov rbp, rdx
    mov rax, [paren_depth]
    cmp rax, [max_depth]
    jae err_too_deep
    cmp rsp, [hard_floor]
    jb err_too_deep
    inc qword [paren_depth]
    inc r12
    cmp ebx, K_TREG
    jne .np
    EMIT 0x50, 0x52                 ; push rax / push rdx (tekst)
.np:
    call ws
    mov r14d, K_CONST               ; brak początku: 0
    xor r15d, r15d
    AT ':'
    je .slice
    xor edi, edi
    call expr
    cmp eax, K_REG
    ja err_index_num
    mov r14d, eax
    mov r15, rdx
    call ws
    AT ']'
    je .single
    AT ':'
    jne err_rbracket
    cmp r14d, K_REG
    jne .slice
    EMIT 0x50                       ; push rax (początek)
.slice:
    inc r12
    call ws
    AT ']'
    je .s_nob
    xor edi, edi
    call expr
    cmp eax, K_REG
    ja err_index_num
    mov edi, eax
    mov rsi, rdx
    call materialize
    EMIT 0x49, 0x89, 0xc0           ; mov r8, rax (koniec)
    call ws
    AT ']'
    jne err_rbracket
    jmp .s_a
.s_nob:
    EMIT 0x49, 0xb8                 ; mov r8, INT64_MAX (do końca)
    mov rax, 0x7fffffffffffffff
    mov rcx, rax
    EMITQ rcx
.s_a:
    inc r12
    cmp r14d, K_REG
    jne .s_a_mem
    EMIT 0x59                       ; pop rcx (początek)
    jmp .s_t
.s_a_mem:
    mov edi, r14d
    mov rsi, r15
    call load_rcx
.s_t:
    call .text_regs
    mov edi, RT_SLICE
    call emit_call_rt
    jmp .done
.single:
    inc r12
    cmp r14d, K_REG
    jne .i_mem
    EMIT 0x48, 0x89, 0xc1           ; mov rcx, rax
    jmp .i_t
.i_mem:
    mov edi, r14d
    mov rsi, r15
    call load_rcx
.i_t:
    call .text_regs
    mov edi, RT_INDEX
    call emit_call_rt
    mov edi, RT_DIE                 ; jc: indeks poza tekstem
    mov esi, 2
    call make_stub
    mov esi, eax
    mov edi, 2
    call emit_jcc_cold
.done:
    dec qword [paren_depth]
    mov eax, K_TREG
    pop r15
    pop r14
    pop rbp
    pop rbx
    ret
; tekst (ebx, rbp) do rax, rdx — ze stosu, gdy był w rejestrach
.text_regs:
    cmp ebx, K_TREG
    jne .tr_mem
    EMIT 0x5a, 0x58                 ; pop rdx / pop rax
    ret
.tr_mem:
    mov edi, ebx
    mov rsi, rbp
    jmp tmaterialize

; utf8_count(rsi=dane, rcx=długość) -> rax = liczba znaków
utf8_count:
    xor eax, eax
.loop:
    test rcx, rcx
    jz .ret
    movzx edx, byte [rsi]
    inc rsi
    dec rcx
    and edx, 0xc0
    cmp edx, 0x80
    je .loop
    inc rax
    jmp .loop
.ret:
    ret

; ===================== instrukcje =====================

; blank — pomija spacje, tabulatory i '\r' (do r13)
blank:
    cmp r12, r13
    jae .done
    mov al, [r12]
    cmp al, ' '
    je .skip
    cmp al, 9
    je .skip
    cmp al, 13
    jne .done
.skip:
    inc r12
    jmp blank
.done:
    ret

; end_check — po instrukcji tylko koniec linii albo komentarz
end_check:
    call blank
    cmp r12, r13
    jae .ok
    cmp byte [r12], '#'
    jne err_trailing
.ok:
    ret


; at_eol -> ZF=1, gdy kursor na końcu linii albo przy komentarzu
at_eol:
    cmp r12, r13
    jae .yes
    cmp byte [r12], '#'
.yes:
    ret

; scan_string — kursor za otwierającym '"'; -> rbx = początek treści,
; rbp = koniec (zamykający '"'), kursor za '"'
scan_string:
    mov rbx, r12
.loop:
    cmp r12, r13
    jae err_unterminated
    movzx eax, byte [r12]
    cmp al, '"'
    je .end
    inc r12
    cmp al, '\'
    jne .loop
    cmp r12, r13
    jae err_unterminated
    inc r12
    jmp .loop
.end:
    mov rbp, r12
    inc r12
    ret

; bare_expr -> eax, rdx: wyrażenie bez cudzysłowu, do '#' albo końca linii;
; kursor za wyrażeniem (i spacjami)
bare_expr:
    push r13
    mov rdi, r12
.scan:                              ; '#' w literale znakowym ('#') to nie komentarz
    cmp rdi, r13
    jae .whole
    mov al, [rdi]
    cmp al, '#'
    je .cut
    inc rdi
    cmp al, '"'
    je .str
    cmp al, "'"
    jne .scan
    cmp rdi, r13
    jae .whole
    cmp byte [rdi], '\'
    jne .one
    inc rdi
.one:
    inc rdi
    cmp rdi, r13
    jae .whole
    cmp byte [rdi], "'"
    jne .scan
    inc rdi
    jmp .scan
.str:                               ; '#' w napisie też nie
    cmp rdi, r13
    jae .whole
    mov al, [rdi]
    inc rdi
    cmp al, '"'
    je .scan
    cmp al, '\'
    jne .str
    cmp rdi, r13
    jae .whole
    inc rdi
    jmp .str
.cut:
    mov r13, rdi
.whole:
    xor edi, edi
    call expr
    push rax
    call ws
    pop rax
    pop r13
    ret

; lbrace — '{' na końcu linii
lbrace:
    call blank
    AT '{'
    jne err_lbrace
    inc r12
    jmp end_check

; emit_cond(eax=rodzaj, rdx=wartość, rsi=adres listy "fałsz") — skok, gdy warunek fałszywy
emit_cond:
    cmp eax, K_CONST
    jne .not_const
    push rsi
    push rdx
    call tmp_done
    pop rdx
    pop rsi
    test rdx, rdx
    jnz .ret                        ; zawsze prawda: bez skoku
    mov edi, -1
    jmp emit_j32
.not_const:
    cmp eax, K_REG
    jne .gen
    cmp qword [stmt_tmp], 0
    jne .gen                        ; najpierw czyszczenie obszaru tekstów
    mov ecx, [code_buf + 8]
    cmp ecx, [last_set_end]
    jne .gen
    ; wynik porównania: zamiast setcc/movzx/test/jz — jeden skok warunkowy
    mov ecx, [last_set_pos]
    mov [code_buf + 8], rcx
    mov dword [last_set_end], -1
    mov edi, [last_set_cc]
    xor edi, 1
    jmp emit_j32
.gen:
    mov edi, eax
    push rsi
    mov rsi, rdx
    call materialize
    call tmp_done
    pop rsi
    EMIT 0x48, 0x85, 0xc0           ; test rax, rax
    mov edi, 4                      ; jz
    jmp emit_j32
.ret:
    ret

; store_var(eax=rodzaj, rdx=wartość, ebx=numer zmiennej) — zapis i oznaczenie
store_var:
    push rbp
    mov ebp, ebx
    shl ebp, 4
    add ebp, D_VARS
    cmp eax, K_REG
    ja .text
    cmp eax, K_CONST
    jne .gen
    movsxd rcx, edx
    cmp rcx, rdx
    jne .gen
    EMIT 0x49, 0xc7, 0x87           ; mov qword [r15 + disp32], imm32
    EMITD ebp
    EMITD edx
    jmp .flag
.gen:
    mov edi, eax
    mov rsi, rdx
    call materialize
    EMIT 0x49, 0x89, 0x87           ; mov [r15 + disp32], rax
    EMITD ebp
    jmp .flag
.text:
    mov edi, eax
    mov rsi, rdx
    call tmaterialize
    EMIT 0x49, 0x8d, 0xbf           ; lea rdi, [r15 + disp32]
    EMITD ebp
    mov edi, RT_SETTEXT
    call emit_call_rt
.flag:
    lea rax, [var_proven]
    cmp byte [rax + rbx], 0
    jne .done
    EMIT 0x41, 0xc6, 0x87           ; mov byte [r15 + disp32 + 8], 1
    add ebp, 8
    EMITD ebp
    EMIT 1
    ; od tej chwili (do końca bieżącego bloku) zmienna na pewno ma wartość
    lea rax, [var_proven]
    mov byte [rax + rbx], 1
    mov rax, [proof_sp]
    lea rcx, [proof_stack]
    mov [rcx + rax*4], ebx
    inc qword [proof_sp]
.done:
    lea rax, [var_assigned]
    mov byte [rax + rbx], 1
    pop rbp
    ret

; proof_restore(rdi=stan stosu dowodów) — zmienne przypisane w zamkniętym
; bloku znów "mogą nie mieć wartości"
proof_restore:
    lea rcx, [proof_stack]
    lea rdx, [var_proven]
.loop:
    mov rax, [proof_sp]
    cmp rax, rdi
    jbe .done
    dec rax
    mov [proof_sp], rax
    mov eax, [rcx + rax*4]
    mov byte [rdx + rax], 0
    jmp .loop
.done:
    ret

; top_block -> rbx = adres wpisu na szczycie stosu bloków
%macro TOP_BLOCK 1
    mov %1, [block_sp]
    dec %1
    shl %1, 5
    lea rax, [blocks]
    add %1, rax
%endmacro

; open_block(edi=rodzaj, esi=początek pętli) -> rbx = nowy wpis
open_block:
    mov rax, [block_sp]
    cmp rax, MAX_BLOCKS
    jae err_too_many_blocks
    inc qword [block_sp]
    TOP_BLOCK rbx
    mov [rbx + BL_KIND], edi
    mov dword [rbx + BL_FALSE], 0
    mov dword [rbx + BL_END], 0
    mov [rbx + BL_START], esi
    mov rax, [proof_sp]
    mov [rbx + BL_MARK], eax
    mov rax, [cur_line]
    mov [rbx + BL_LINE], rax
    ret

; statement — jedna linia programu [r12, r13)
statement:
    push rbx
    push rbp
    push r14
    push r15
    call blank
    cmp r12, r13
    jae .ret
    movzx eax, byte [r12]
    cmp al, '#'
    je .ret
    cmp al, '}'
    je .close
    lea rcx, [ident_tab]
    cmp byte [rcx + rax], 0
    je err_char
    sub eax, '0'
    cmp eax, 9
    jbe err_char
    mov rbx, r12
    call skip_ident
    mov rbp, r12
    sub rbp, rbx                    ; rbx = nazwa, rbp = długość
    cmp rbp, 6
    jne .not_import
    cmp dword [rbx], 'impo'
    jne .not_import
    cmp word [rbx + 4], 'rt'
    jne .not_import
    ; "import" i za spacją nazwa: import modułu; "import = 1" to nadal zmienna
    call blank
    call at_eol
    je err_import_name
    movzx eax, byte [r12]
    lea rcx, [ident_tab]
    cmp byte [rcx + rax], 0
    je .import_var
    sub eax, '0'
    cmp eax, 9
    jbe .import_var
    cmp byte [seen_stmt], 0
    jne err_import_late
    call imp_statement
    jmp .ret
.import_var:
    lea r12, [rbx + 6]
.not_import:
    mov byte [seen_stmt], 1
    mov rdi, rbx
    mov rsi, rbp
    call kw_id
    cmp eax, KW_PRINT
    je .print
    cmp eax, KW_CALC
    je .calc
    cmp eax, KW_IF
    je .if
    cmp eax, KW_WHILE
    je .while
    cmp eax, KW_ELSE
    je err_else
    cmp eax, KW_BREAK
    je .break
    cmp eax, KW_CONTINUE
    je .continue
    cmp eax, KW_WRITE
    je .write
    test eax, eax
    jnz err_char                    ; and / or / not na początku instrukcji
    jmp .assign
.ret:
    pop r15
    pop r14
    pop rbp
    pop rbx
    ret

; --- print(...) / write(...): napis, tekst albo liczba (print z '\n') ---
.write:
    call open_paren
    mov dword [str_nl], 0
    jmp .out
.print:
    call open_paren
    mov dword [str_nl], 1
.out:
    AT '"'
    jne .out_expr
    ; sam napis w cudzysłowie: jedna stała (z '\n' dla print)
    mov r14, r12
    inc r12
    call scan_string
    call blank
    AT ')'
    je .str
    ; dalej operator albo indeks: napis to początek wyrażenia,
    ; inaczej (koniec linii, inne znaki) brak ')' po napisie
    AT '['
    je .str_expr
    call peek_binop
    test eax, eax
    jz err_rparen
.str_expr:
    mov r12, r14
    jmp .out_expr
.str:
    inc r12
    call end_check
    mov ecx, [str_nl]
    call text_const
    mov r14, rax                    ; przesunięcie napisu
    mov r15, rdx                    ; długość (z '\n')
    EMIT 0x48, 0x8d, 0x35           ; lea rsi, [rip + napis]
    mov edi, S_CONST
    mov esi, r14d
    call emit_rel
    mov eax, 0xffffffff
    cmp r15, rax
    ja .p_big
    EMIT 0xba                       ; mov edx, imm32
    EMITD r15d
    jmp .p_call
.p_big:
    EMIT 0x48, 0xba                 ; mov rdx, imm64
    EMITQ r15
.p_call:
    mov edi, RT_WRITE
    call emit_call_rt
    jmp .ret
.out_expr:
    call bare_expr
    mov r14d, eax
    mov r15, rdx
    call blank
    AT ')'
    jne err_rparen_expr
    inc r12
    call end_check
    mov edi, r14d
    mov rsi, r15
    cmp edi, K_REG
    ja .out_text
    call materialize
    mov edi, RT_INT
    cmp dword [str_nl], 0
    je .out_int
    mov edi, RT_INT_NL
.out_int:
    call emit_call_rt
    jmp .out_done
.out_text:
    call tmaterialize
    EMIT 0x48, 0x89, 0xc6           ; mov rsi, rax
    mov edi, RT_WRITE
    call emit_call_rt
    cmp dword [str_nl], 0
    je .out_done
    mov edi, RT_NL
    call emit_call_rt
.out_done:
    call tmp_done
    jmp .ret

; --- calc("wyrażenie") albo calc(wyrażenie) ---
.calc:
    call open_paren
    AT '"'
    jne .c_bare
    inc r12
    call scan_string
    call close_paren_str
    mov r14, r12                    ; wyrażenie w treści napisu
    mov r15, r13
    mov r12, rbx
    mov r13, rbp
    xor edi, edi
    call expr
    push rax
    call ws
    pop rax
    cmp r12, r13
    jb err_unexpected
    mov r12, r14
    mov r13, r15
    jmp .c_emit
.c_bare:
    call bare_expr
    mov r14d, eax
    mov r15, rdx
    call blank
    AT ')'
    jne err_rparen_expr
    inc r12
    call end_check
    mov eax, r14d
    mov rdx, r15
.c_emit:
    mov edi, eax
    mov rsi, rdx
    call materialize
    mov edi, RT_INT_NL
    call emit_call_rt
    call tmp_done
    jmp .ret

; --- if warunek { ---
.if:
    call bare_expr
    mov r14d, eax
    mov r15, rdx
    call lbrace
    mov edi, B_IF
    xor esi, esi
    call open_block
.cond:
    mov eax, r14d
    mov rdx, r15
    lea rsi, [rbx + BL_FALSE]
    call emit_cond
    jmp .ret

; --- while warunek { ---
.while:
    CODE_POS rax
    push rax                        ; początek pętli: tu liczy się warunek
    call bare_expr
    mov r14d, eax
    mov r15, rdx
    call lbrace
    mov edi, B_WHILE
    pop rsi
    call open_block
    jmp .cond

; --- break / continue ---
.break:
.continue:
    push rax
    call end_check
    pop rax
    mov rcx, [block_sp]
    lea rbx, [blocks]
.find:
    test rcx, rcx
    jz .no_loop
    dec rcx
    mov rdx, rcx
    shl rdx, 5
    cmp dword [rbx + rdx + BL_KIND], B_WHILE
    jne .find
    add rbx, rdx
    cmp eax, KW_BREAK
    jne .cont
    mov edi, -1
    lea rsi, [rbx + BL_FALSE]       ; wyjścia z pętli
    call emit_j32
    jmp .ret
.cont:
    mov esi, [rbx + BL_START]
    call emit_jmp_back
    jmp .ret
.no_loop:
    cmp eax, KW_BREAK
    je err_break
    jmp err_continue

; --- przypisanie: nazwa = wyrażenie / nazwa op= wyrażenie ---
.assign:
    call blank
    cmp r12, r13
    jae err_assign
    movzx eax, byte [r12]
    cmp al, '('
    je err_unknown
    xor r14d, r14d                  ; operator (0 = zwykłe przypisanie)
    lea rcx, [r12 + 1]
    xor edx, edx
    cmp rcx, r13
    jae .a_one
    mov dl, [r12 + 1]
.a_one:
    cmp al, '='
    jne .a_op
    cmp dl, '='
    je err_assign
    inc r12
    jmp .a_var
.a_op:
    cmp dl, '='
    jne err_assign
    mov r14d, OP_ADD
    cmp al, '+'
    je .a_op_ok
    mov r14d, OP_SUB
    cmp al, '-'
    je .a_op_ok
    mov r14d, OP_MUL
    cmp al, '*'
    je .a_op_ok
    mov r14d, OP_DIV
    cmp al, '/'
    je .a_op_ok
    mov r14d, OP_MOD
    cmp al, '%'
    jne err_assign
.a_op_ok:
    add r12, 2
.a_var:
    mov rdi, rbx
    mov rsi, rbp
    call lookup
    test r14d, r14d
    jz .a_plain
    cmp eax, -1
    je .a_unknown
    lea rdx, [var_assigned]
    cmp byte [rdx + rax], 0
    je .a_unknown
    jmp .a_have
.a_unknown:
    mov rdx, rbx
    mov ecx, ebp
    jmp die_unknown_var
.a_plain:
    cmp eax, -1
    jne .a_have
    ; nowa zmienna
    mov rax, [nvars]
    cmp rax, MAX_VARS
    jae err_too_many_vars
    inc qword [nvars]
    lea rdx, [htab]
    shl rcx, 4
    mov [rdx + rcx], rbx
    mov [rdx + rcx + 8], ebp
    lea r8d, [rax + 1]
    mov [rdx + rcx + 12], r8d
    lea rdx, [var_ptr]
    mov [rdx + rax*8], rbx
    lea rdx, [var_len]
    mov [rdx + rax*4], ebp
.a_have:
    mov ebx, eax                    ; numer zmiennej
    test r14d, r14d
    jz .a_expr
    mov edi, ebx
    call emit_var_check             ; x op= ...: x musi mieć wartość
.a_expr:
    call bare_expr
    push rax
    push rdx
    call end_check
    pop rdx
    pop rax
    lea rcx, [var_type]
    movzx ecx, byte [rcx + rbx]     ; 0 = nowa, 1 = liczba, 2 = tekst
    test r14d, r14d
    jz .a_plain_type
    cmp ecx, 2
    je .a_text_op
    cmp eax, K_REG
    ja .a_mismatch
    mov ecx, eax                    ; x op wyrażenie
    mov edi, r14d
    mov esi, K_VAR
    mov r8d, ebx
    mov r9, -1
    call gen_binop
    jmp .a_store
.a_text_op:
    ; s += wyrażenie: dopisanie (liczba jako tekst); inne działania to błąd
    cmp r14d, OP_ADD
    jne err_text_op
    mov edi, eax
    mov rsi, rdx
    call to_text
    mov r8, rdx
    shr r8, 32
    cmp eax, K_TLIT
    jne .a_append
    dec r8
    cmp r8, 3
    jbe .a_append_short
.a_append:
    mov edi, eax
    mov rsi, rdx
    call tmaterialize
    EMIT 0x49, 0x8d, 0xbf           ; lea rdi, [r15 + disp32]
    mov eax, ebx
    shl eax, 4
    add eax, D_VARS
    mov ecx, eax
    EMITD ecx
    mov edi, RT_APPEND
    call emit_call_rt
    jmp .a_done
.a_append_short:
    ; s += "1-4 B": w kodzie jeden zapis 4 B, gdy jest miejsce w bloku
    push rdx
    EMIT 0x4d, 0x8b, 0x8f           ; mov r9, [r15 + disp32]
    mov ecx, ebx
    shl ecx, 4
    add ecx, D_VARS
    EMITD ecx
    EMIT 0x4d, 0x8b, 0x51, 0x08, 0x4d, 0x8d, 0x5a, 0x04, 0x4d, 0x3b, 0x19, 0x77, 0
    mov r9, [code_buf + 8]          ; ↑ mov r10, [r9 + 8] / lea r11, [r10 + 4]
    EMIT 0x43, 0xc7, 0x44, 0x11, 0x10   ; cmp r11, [r9] / ja wolno
    mov rdx, [rsp]                  ; mov dword [r9 + r10 + 16], bajty napisu
    mov rsi, [const_buf]
    mov ecx, edx
    add rsi, rcx
    shr rdx, 32
    xor eax, eax
.a_as_byte:
    dec edx
    js .a_as_imm
    shl eax, 8
    mov al, [rsi + rdx]
    jmp .a_as_byte
.a_as_imm:
    mov ecx, eax
    EMITD ecx
    EMIT 0x49, 0x83, 0xc2           ; add r10, długość
    mov rdx, [rsp]
    shr rdx, 32
    EMIT dl
    EMIT 0x4d, 0x89, 0x51, 0x08, 0xeb, 0    ; mov [r9 + 8], r10 / jmp dalej
    mov rax, [code_buf]
    mov rcx, [code_buf + 8]
    mov edx, ecx
    sub edx, r9d
    mov [rax + r9 - 1], dl          ; ja -> wolna ścieżka
    push rcx
    mov edi, K_TLIT
    mov rsi, [rsp + 8]
    call tmaterialize
    EMIT 0x49, 0x8d, 0xbf           ; lea rdi, [r15 + disp32]
    mov ecx, ebx
    shl ecx, 4
    add ecx, D_VARS
    EMITD ecx
    mov edi, RT_APPEND
    call emit_call_rt
    pop rcx
    pop rdx
    mov rax, [code_buf]
    mov rdx, [code_buf + 8]
    sub edx, ecx
    mov [rax + rcx - 1], dl         ; jmp -> za wolną ścieżką
    jmp .a_done
.a_plain_type:
    ; rodzaj zmiennej ustala pierwsze przypisanie w tekście programu
    mov r8d, 1
    cmp eax, K_REG
    jbe .a_kind
    mov r8d, 2
.a_kind:
    test ecx, ecx
    jz .a_set_type
    cmp ecx, r8d
    jne .a_mismatch
    jmp .a_store
.a_set_type:
    lea rcx, [var_type]
    mov [rcx + rbx], r8b
.a_store:
    call store_var
.a_done:
    call tmp_done
    jmp .ret
.a_mismatch:
    ; ecx = rodzaj zmiennej
    lea r8, [msg_is_num]
    mov r9d, msg_is_num_len
    cmp ecx, 1
    je .a_mm_msg
    lea r8, [msg_is_text]
    mov r9d, msg_is_text_len
.a_mm_msg:
    lea rax, [var_ptr]
    mov rdx, [rax + rbx*8]
    lea rax, [var_len]
    mov ecx, [rax + rbx*4]
    lea rdi, [msg_var1]
    mov esi, msg_var1_len
    jmp die_name

; --- } / } else { / } else if warunek { ---
.close:
    mov byte [seen_stmt], 1
    cmp qword [block_sp], 0
    je err_rbrace
    inc r12
    call blank
    cmp r12, r13
    jae .pop
    cmp byte [r12], '#'
    je .pop
    mov r14, r12
    call skip_ident
    mov rdi, r14
    mov rsi, r12
    sub rsi, r14
    call kw_id
    cmp eax, KW_ELSE
    jne err_trailing
    TOP_BLOCK rbx
    cmp dword [rbx + BL_KIND], B_IF
    jne err_else
    call blank
    ; koniec gałęzi if: skok na koniec całego łańcucha, potem gałąź else
    mov edi, -1
    lea rsi, [rbx + BL_END]
    call emit_j32
    mov edi, [rbx + BL_FALSE]
    CODE_POS rsi
    call resolve
    mov dword [rbx + BL_FALSE], 0
    mov edi, [rbx + BL_MARK]
    call proof_restore
    mov rax, [cur_line]
    mov [rbx + BL_LINE], rax
    AT '{'
    jne .else_if
    inc r12
    call end_check
    mov dword [rbx + BL_KIND], B_ELSE
    jmp .ret
.else_if:
    mov r14, r12
    call skip_ident
    mov rdi, r14
    mov rsi, r12
    sub rsi, r14
    call kw_id
    cmp eax, KW_IF
    jne err_lbrace
    push rbx
    call bare_expr
    mov r14d, eax
    mov r15, rdx
    call lbrace
    pop rbx
    jmp .cond
.pop:
    TOP_BLOCK rbx
    cmp dword [rbx + BL_KIND], B_WHILE
    jne .pop_if
    mov esi, [rbx + BL_START]
    call emit_jmp_back
.pop_if:
    CODE_POS r14
    mov edi, [rbx + BL_FALSE]
    mov esi, r14d
    call resolve
    mov edi, [rbx + BL_END]
    mov esi, r14d
    call resolve
    mov edi, [rbx + BL_MARK]
    call proof_restore
    dec qword [block_sp]
    jmp .ret

; open_paren — '(' po nazwie instrukcji i spacje za nim
open_paren:
    call blank
    AT '('
    jne err_lparen
    inc r12
    jmp blank

; close_paren_str — ')' po napisie i koniec instrukcji
close_paren_str:
    call blank
    AT ')'
    jne err_rparen
    inc r12
    jmp end_check

; emit_jmp_back(esi=cel) — jmp rel32 wstecz
emit_jmp_back:
    EMIT 0xe9
    CODE_POS rax
    add eax, 4
    sub esi, eax
    EMITD esi
    ret

; ===================== kompilacja całego pliku =====================

; comp_compile(rdi=kod, rsi=długość) — kompiluje program do obrazu (img_ptr)
comp_compile:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    lea rax, [rdi + rsi]
    mov [src_end], rax
    mov r14, rdi                    ; początek bieżącej linii
    ; limit nawiasów jak w expr.asm: (budżet - 16) / 48 + 1
    mov rax, [stack_budget]
    sub rax, 16
    xor edx, edx
    mov ecx, 48
    div rcx
    inc rax
    mov [max_depth], rax
    mov rax, [stack_budget]
    lea rax, [rax + rax*2]
    mov rcx, rsp
    sub rcx, rax
    mov [hard_floor], rcx
    mov qword [cur_line], 1
    mov edi, RT_SANDBOX             ; najpierw blokady z importów (rt_sandbox)
    call emit_call_rt
.line:
    cmp r14, [src_end]
    jae .eof
    mov rdi, r14
    mov rcx, [src_end]
    sub rcx, r14
    mov al, 10
    repne scasb
    jne .last
    dec rdi
.last:
    mov [line_eol], rdi
    mov r12, r14
    mov r13, rdi
    mov dword [stub_ovf], -1
    mov dword [stub_div], -1
    call statement
    mov r14, [line_eol]
    inc r14
    inc qword [cur_line]
    jmp .line
.eof:
    cmp qword [block_sp], 0
    je .done
    TOP_BLOCK rbx
    mov rax, [rbx + BL_LINE]
    mov [cur_line], rax
    jmp err_unclosed
.done:
    mov edi, RT_EXIT
    call emit_call_rt
    call imp_policy
    mov [pol_off], rax
    call link
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; link — składa obraz: rt, nagłówek, kod, kod rzadki, stałe; nazwy zmiennych
; (do komunikatów błędów) trafiają na koniec stałych
link:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    ; nazwy zmiennych
    xor ebx, ebx
.names:
    cmp rbx, [nvars]
    jae .table
    lea rax, [var_len]
    mov eax, [rax + rbx*4]
    mov ecx, [const_buf + 8]
    lea rdx, [var_off]
    mov [rdx + rbx*4], ecx
    push rax
    call const_need
    mov rdi, rax
    pop rcx
    lea rax, [var_ptr]
    mov rsi, [rax + rbx*8]
    rep movsb
    inc rbx
    jmp .names
.table:
    mov r15d, [const_buf + 8]       ; przesunięcie tabeli nazw w stałych
    mov rax, [nvars]
    shl rax, 3
    call const_need
    mov rdi, rax
    xor ebx, ebx
.tab_loop:
    cmp rbx, [nvars]
    jae .layout
    lea rax, [var_off]
    mov eax, [rax + rbx*4]
    mov [rdi + rbx*8], eax          ; przesunięcie w stałych (+ początek stałych niżej)
    lea rax, [var_len]
    mov eax, [rax + rbx*4]
    mov [rdi + rbx*8 + 4], eax
    inc rbx
    jmp .tab_loop
.layout:
    ; początki części: rt 0, kod H0, kod rzadki, stałe
    mov r12d, [rt_table + RT_SIZE*4]
    add r12, HDR_SIZE               ; r12 = H0
    mov r13, r12
    add r13, [code_buf + 8]         ; r13 = kod rzadki
    mov r14, r13
    add r14, [cold_buf + 8]         ; r14 = stałe
    mov rbp, r14
    add rbp, [const_buf + 8]        ; rbp = długość obrazu
    mov [img_len], rbp
    ; tabela nazw: przesunięcia względem początku obrazu
    mov rdi, [const_buf]
    add rdi, r15
    xor ebx, ebx
.tab_fix:
    cmp rbx, [nvars]
    jae .alloc
    add [rdi + rbx*8], r14d
    inc rbx
    jmp .tab_fix
.alloc:
    lea rsi, [rbp + 4095]
    and rsi, -4096
    mov [img_cap], rsi
    mov eax, SYS_MMAP
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae nomem
    mov rbx, rax
    mov [img_ptr], rax
    ; rt
    mov rdi, rbx
    lea rsi, [rt_begin]
    mov ecx, [rt_table + RT_SIZE*4]
    rep movsb
    ; nagłówek: przesunięcie tabeli nazw
    lea rax, [r14 + r15]
    stosq
    mov rax, [pol_off]              ; przesunięcie opisu uprawnień
    add rax, r14
    stosq
    ; kod, kod rzadki, stałe
    mov rsi, [code_buf]
    mov rcx, [code_buf + 8]
    rep movsb
    mov rsi, [cold_buf]
    mov rcx, [cold_buf + 8]
    rep movsb
    mov rsi, [const_buf]
    mov rcx, [const_buf + 8]
    rep movsb
    ; poprawki rel32: cel - (adres pola + 4)
    sub rsp, 32
    mov qword [rsp], 0              ; początki części: S_RT, S_HOT, S_COLD, S_CONST
    mov [rsp + 8], r12
    mov [rsp + 16], r13
    mov [rsp + 24], r14
    mov rsi, [fix_buf]
    mov rcx, [fix_buf + 8]
    add rcx, rsi
.fix:
    cmp rsi, rcx
    jae .fixed
    movzx eax, byte [rsi + 8]       ; część źródłowa
    mov rdx, [rsp + rax*8]
    mov eax, [rsi]
    add rdx, rax                    ; adres pola w obrazie
    movzx eax, byte [rsi + 9]       ; część celu
    mov rdi, [rsp + rax*8]
    mov eax, [rsi + 4]
    add rdi, rax                    ; adres celu w obrazie
    sub rdi, rdx
    sub rdi, 4
    mov [rbx + rdx], edi
    add rsi, 16
    jmp .fix
.fixed:
    add rsp, 32
    ; obszar danych: bufor wyjścia + zmienne
    mov rax, [nvars]
    shl rax, 4
    add rax, D_VARS
    mov [data_size], rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; comp_run_jit(rdi=ścieżka programu) — uruchamia złożony obraz w pamięci (nie wraca)
comp_run_jit:
    push rdi
    mov eax, SYS_MPROTECT
    mov rdi, [img_ptr]
    mov rsi, [img_cap]
    mov edx, PROT_READ | PROT_EXEC
    syscall
    test rax, rax
    jnz nomem
    mov eax, SYS_MMAP
    xor edi, edi
    mov rsi, [data_size]
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae nomem
    mov r15, rax
    pop rdi
    cmp byte [imp_need_base], 0
    je .start
    ; folder programu (dla import files ./folder): katalog ze ścieżki pliku
    sub rsp, PATH_MAX
    mov rsi, rdi
    mov rdi, rsp
    xor ecx, ecx                    ; pozycja za ostatnim '/'
.copy:
    mov al, [rsi]
    test al, al
    jz .copied
    mov [rdi], al
    inc rsi
    inc rdi
    cmp al, '/'
    jne .copy_next
    mov rcx, rdi
.copy_next:
    mov rax, rdi
    sub rax, rsp
    cmp rax, PATH_MAX - 2
    jb .copy
.copied:
    test rcx, rcx
    jnz .cut
    mov rcx, rsp                    ; bez '/': bieżący folder
    mov byte [rcx], '.'
    inc rcx
.cut:
    mov byte [rcx], 0
    mov eax, SYS_OPENAT
    mov edi, AT_FDCWD
    mov rsi, rsp
    mov edx, O_PATH | O_DIRECTORY | O_CLOEXEC
    syscall
    add rsp, PATH_MAX
    inc rax
    test rax, rax
    jg .base
    mov rax, -1                     ; folderu nie ma: reguły względne nie działają
.base:
    mov [r15 + D_BASEFD], rax
.start:
    mov eax, [rt_table + RT_SIZE*4]
    add rax, HDR_SIZE
    add rax, [img_ptr]
    jmp rax

; comp_write_elf(rdi=ścieżka) — zapisuje obraz jako plik ELF:
;   segment 1 (R+X): nagłówki, start (mov r15, dane / jmp kod), obraz
;   segment 2 (RW): obszar danych, wypełniony zerami przez jądro
comp_write_elf:
    push rbx
    mov rbx, rdi
    lea rdi, [elf_hdr]
    xor eax, eax
    mov ecx, 192 / 8
    rep stosq
    lea rdi, [elf_hdr]
    mov dword [rdi], 0x464c457f     ; "\x7fELF"
    mov dword [rdi + 4], 0x00010102 ; 64-bit, LE, wersja 1
    mov word [rdi + 16], 2          ; ET_EXEC
    mov word [rdi + 18], 0x3e       ; x86-64
    mov dword [rdi + 20], 1
    mov qword [rdi + 24], BASE + 176    ; e_entry: kod startowy
    mov qword [rdi + 32], 64        ; e_phoff
    mov word [rdi + 52], 64         ; e_ehsize
    mov word [rdi + 54], 56         ; e_phentsize
    mov word [rdi + 56], 2          ; e_phnum
    mov word [rdi + 58], 64         ; e_shentsize
    ; segment kodu
    mov rax, [img_len]
    add rax, 176 + 15
    mov dword [rdi + 64], 1         ; PT_LOAD
    mov dword [rdi + 68], 5         ; R + X
    mov qword [rdi + 80], BASE
    mov qword [rdi + 88], BASE
    mov [rdi + 96], rax
    mov [rdi + 104], rax
    mov qword [rdi + 112], 0x1000
    ; segment danych: pod pierwszą wolną stroną za kodem
    lea rcx, [rax + BASE + 4095]
    and rcx, -4096
    mov dword [rdi + 120], 1
    mov dword [rdi + 124], 6        ; R + W
    mov [rdi + 136], rcx
    mov [rdi + 144], rcx
    mov rax, [data_size]
    mov [rdi + 160], rax            ; p_memsz (p_filesz = 0)
    mov qword [rdi + 168], 0x1000
    ; kod startowy: mov r15, dane / jmp kod programu
    mov word [rdi + 176], 0xbf49
    mov [rdi + 178], rcx
    mov byte [rdi + 186], 0xe9
    mov eax, [rt_table + RT_SIZE*4]
    add eax, HDR_SIZE
    mov [rdi + 187], eax
    mov rdi, rbx
    lea rsi, [elf_hdr]
    mov edx, 176 + 15
    mov rcx, [img_ptr]
    mov r8, [img_len]
    call write_file2
    pop rbx
    ret

CERR err_char,          "nieoczekiwany znak na początku instrukcji"
CERR err_lparen,        "oczekiwano '(' po nazwie instrukcji"
CERR err_unterminated,  "niezamknięty napis"
CERR err_rparen,        "oczekiwano ')' po napisie"
CERR err_rparen_expr,   "oczekiwano ')' po wyrażeniu"
CERR err_trailing,      "nieoczekiwane znaki po instrukcji"
CERR err_unknown,       "nieznana instrukcja (znane: print, calc)"
CERR err_escape,        'nieznana sekwencja ucieczki (znane: \n \t \\ \")'
CERR err_assign,        "oczekiwano '=' po nazwie zmiennej"
CERR err_lbrace,        "oczekiwano '{' na końcu linii"
CERR err_rbrace,        "'}' bez otwartego bloku"
CERR err_unclosed,      "niezamknięty blok: brak '}'"
CERR err_else,          "else bez if"
CERR err_break,         "break poza pętlą"
CERR err_continue,      "continue poza pętlą"
CERR err_too_many_vars, "za dużo zmiennych (max 65536)"
CERR err_too_many_blocks, "bloki zbyt głęboko zagnieżdżone (max 65536)"
CERR err_unexpected,    "nieoczekiwany znak w wyrażeniu"
CERR err_incomplete,    "niekompletne wyrażenie"
CERR err_rparen_e,      "brak ')' w wyrażeniu"
CERR err_big,           "liczba za duża (max 9223372036854775807)"
CERR err_too_deep,      "wyrażenie zbyt głęboko zagnieżdżone"
CERR err_func,          "oczekiwano '()' po nazwie funkcji"
CERR err_import_name,   "oczekiwano nazwy modułu po import (znane: math, files, commands, net)"
CERR err_import_late,   "import musi być na początku pliku, przed innymi instrukcjami"
CERR err_need_num,      "tu potrzebna jest liczba, nie tekst"
CERR err_text_op,       "tekst można tylko łączyć (+) i porównywać (== !=)"
CERR err_cmp_mix,       "nie można porównać tekstu z liczbą"
CERR err_text_chain,    "porównań tekstów nie można łączyć w łańcuch (użyj and)"
CERR err_len_text,      "len przyjmuje tekst"
CERR err_index_int,     "indeks [ ] działa tylko na tekście"
CERR err_index_num,     "indeks musi być liczbą"
CERR err_rbracket,      "brak ']' po indeksie"
CERR err_char_lit,      "zły zapis znaku (przykład: '+')"
