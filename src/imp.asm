; imp.asm — importy Fih 0.4: uprawnienia programu
;
;   import math                          funkcje matematyczne
;   import files [folder] [only f, ...]  pliki (folder względem folderu programu)
;   import commands [only ls, git]       polecenia systemu
;   import net [domena] [only get, ...]  sieć (w only także domeny)
;
; Bez importu program nie ma żadnego z tych uprawnień. Importy stoją na
; początku pliku. Kilka importów jednego modułu sumuje uprawnienia.
;
; Wynik dla środowiska (imp_policy, w stałych obrazu; rt_sandbox w rt.asm
; zakłada na jego podstawie blokady jądra — Landlock i seccomp):
;   dd flagi POL_*, dd liczba reguł plików,
;   reguła: dq prawa Landlock, dw długość ścieżki z zerem, ścieżka, 0
%include "fih.inc"
default rel

global imp_statement, imp_policy, imp_need_base, imp_mods, imp_funcs, imp_reset, imp_math
extern blank, skip_ident, end_check, const_need, const_buf, buf_need, ident_tab, die, die_name

%define M_MATH     0
%define M_FILES    1
%define M_COMMANDS 2
%define M_NET      3

; prawa Landlock (uapi/linux/landlock.h)
%define LL_WRITE_FILE  2
%define LL_READ_FILE   4
%define LL_READ_DIR    8
%define LL_REMOVE_DIR  16
%define LL_REMOVE_FILE 32
%define LL_MAKE_DIR    128
%define LL_MAKE_REG    256
%define LL_REFER       0x2000
%define LL_TRUNCATE    0x4000
%define LL_ALL_NO_EXEC 0xfffe       ; wszystkie prawa poza uruchamianiem

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

section .rodata
mod_tab:    db 4, "math", 5, "files", 8, "commands", 3, "net", 0
; (kolejność = numery w comp_flt.inc, math_desc)
math_fn:    db 3, "abs", 3, "min", 3, "max", 3, "pow", 4, "sqrt", 5, "floor"
            db 4, "ceil", 5, "round", 5, "trunc", 3, "sin", 3, "cos", 3, "tan"
            db 4, "asin", 4, "acos", 4, "atan", 5, "atan2", 3, "log", 4, "log2"
            db 5, "log10", 3, "exp", 5, "hypot", 6, "random", 2, "pi", 1, "e", 0
files_fn:   db 4, "read", 5, "write", 6, "append", 6, "exists", 6, "delete"
            db 6, "rename", 5, "mkdir", 4, "list", 0
net_fn:     db 3, "get", 4, "post", 8, "download", 3, "tcp", 0
fn_tabs:    dd math_fn - mod_tab, files_fn - mod_tab, 0, net_fn - mod_tab
; prawa Landlock potrzebne funkcjom files (kolejność jak w files_fn)
files_rights:
    dq LL_READ_FILE
    dq LL_WRITE_FILE | LL_MAKE_REG | LL_TRUNCATE
    dq LL_WRITE_FILE | LL_MAKE_REG
    dq 0
    dq LL_REMOVE_FILE | LL_REMOVE_DIR
    dq LL_REFER | LL_MAKE_REG | LL_REMOVE_FILE | LL_MAKE_DIR | LL_REMOVE_DIR
    dq LL_MAKE_DIR
    dq LL_READ_DIR
mod_pol:    db POL_MATH, POL_FILES, POL_COMMANDS, POL_NET
str_only:   db "only"
str_local:  db "localhost"
msg_mod1:   db "nieznany moduł '"
msg_mod1_len equ $ - msg_mod1
msg_mod2:   db "' (znane: math, files, commands, net)"
msg_mod2_len equ $ - msg_mod2
msg_fn1:    db "nieznana funkcja '"
msg_fn1_len equ $ - msg_fn1
msg_fn_math: db "' w module math (znane: abs, min, max, pow, sqrt, floor, ceil, round, trunc, sin, cos, tan, asin, acos, atan, atan2, log, log2, log10, exp, hypot, random, pi, e)"
msg_fn_math_len equ $ - msg_fn_math
msg_fn_files: db "' w module files (znane: read, write, append, exists, delete, rename, mkdir, list)"
msg_fn_files_len equ $ - msg_fn_files
msg_fn_net: db "' w module net (znane: get, post, download, tcp albo domena, np. example.com)"
msg_fn_net_len equ $ - msg_fn_net
fn_msgs:    dd msg_fn_math - mod_tab, msg_fn_math_len, msg_fn_files - mod_tab, msg_fn_files_len
            dd 0, 0, msg_fn_net - mod_tab, msg_fn_net_len

section .bss
imp_mods:   resq 1          ; zaimportowane moduły (POL_*)
imp_need_base: resq 1       ; 1 = jest reguła z folderem względnym
imp_funcs:  resd 4          ; dozwolone funkcje modułu (bit = pozycja w tabeli)
rule_buf:   resq 3          ; reguły plików: dq prawa, dq ścieżka (0 = "/"), dq długość
cmd_buf:    resq 3          ; dozwolone polecenia: dq nazwa, dq długość
dom_buf:    resq 3          ; dozwolone domeny: dq nazwa, dq długość
cmd_all:    resq 1          ; 1 = wszystkie polecenia
dom_all:    resq 1          ; 1 = wszystkie domeny
place_ptr:  resq 1
place_len:  resq 1
cur_mask:   resq 1
have_dom:   resq 1

section .text

; tab_find(rdi=tabela "dł, tekst", rsi=nazwa, rdx=długość) -> eax = pozycja albo -1
tab_find:
    xor eax, eax
.next:
    movzx ecx, byte [rdi]
    test ecx, ecx
    jz .none
    cmp rcx, rdx
    jne .skip
    xor r8d, r8d
.cmp:
    cmp r8d, ecx
    je .found
    mov r9b, [rsi + r8]
    cmp r9b, [rdi + 1 + r8]
    jne .skip
    inc r8d
    jmp .cmp
.skip:
    lea rdi, [rdi + rcx + 1]
    inc eax
    jmp .next
.none:
    mov eax, -1
.found:
    ret

; at_end -> ZF=1, gdy kursor na końcu linii albo przy komentarzu
at_end:
    cmp r12, r13
    jae .yes
    cmp byte [r12], '#'
.yes:
    ret

; at_only -> ZF=1, gdy kursor stoi na słowie "only" (za nim spacja albo koniec)
at_only:
    lea rax, [r12 + 4]
    cmp rax, r13
    ja .no
    cmp dword [r12], 'only'
    jne .no
    cmp rax, r13
    je .yes
    movzx eax, byte [rax]
    lea rcx, [ident_tab]
    cmp byte [rcx + rax], 0
    jne .no
.yes:
    cmp eax, eax
    ret
.no:
    test r12, r12           ; ZF = 0 (r12 nigdy nie jest zerem)
    ret

; tok_place — kursor przesuwa się za słowo do spacji, '#' albo ','
; -> rbx = początek, rdx = długość; bajty sterujące są błędem
tok_place:
    mov rbx, r12
.loop:
    cmp r12, r13
    jae .done
    movzx eax, byte [r12]
    cmp al, ' '
    je .done
    cmp al, 9
    je .done
    cmp al, 13
    je .done
    cmp al, '#'
    je .done
    cmp al, ','
    je .done
    cmp al, ' '
    jb err_imp_char
    cmp al, 127
    je err_imp_char
    inc r12
    jmp .loop
.done:
    mov rdx, r12
    sub rdx, rbx
    ret

; is_domain(rbx=słowo, rdx=długość) -> ZF=1, gdy to adres: litery, cyfry,
; '-' i '.', z kropką w środku (albo "localhost")
is_domain:
    cmp rdx, 9
    jne .chars
    mov rax, [str_local]
    cmp rax, [rbx]
    jne .chars
    mov al, [str_local + 8]
    cmp al, [rbx + 8]
    je .yes
.chars:
    xor ecx, ecx
    xor r8d, r8d            ; 1 = była kropka
.loop:
    cmp rcx, rdx
    jae .end
    movzx eax, byte [rbx + rcx]
    cmp al, '.'
    je .dot
    cmp al, '-'
    je .ok
    lea r9, [ident_tab]
    cmp byte [r9 + rax], 0
    je .no
    cmp al, '_'
    je .no
    jmp .ok
.dot:
    test rcx, rcx
    jz .no                  ; kropka na początku
    cmp byte [rbx + rcx - 1], '.'
    je .no                  ; dwie kropki
    mov r8d, 1
.ok:
    inc rcx
    jmp .loop
.end:
    test r8d, r8d
    jz .no
    cmp byte [rbx + rdx - 1], '.'
    je .no                  ; kropka na końcu
.yes:
    cmp eax, eax
    ret
.no:
    test rbx, rbx           ; ZF = 0
    ret

; check_path(rbx=ścieżka, rdx=długość) — folder względny, bez ".."
check_path:
    cmp byte [rbx], '/'
    je err_imp_abs
    xor ecx, ecx            ; początek bieżącej części
.part:
    mov r8, rcx
.scan:
    cmp r8, rdx
    jae .last
    cmp byte [rbx + r8], '/'
    je .cut
    inc r8
    jmp .scan
.cut:
    call .check_dots
    lea rcx, [r8 + 1]
    jmp .part
.last:
    call .check_dots
    ret
; część [rcx, r8) równa ".." jest błędem
.check_dots:
    mov rax, r8
    sub rax, rcx
    cmp rax, 2
    jne .ret
    cmp word [rbx + rcx], '..'
    je err_imp_up
.ret:
    ret

; add_pair(rdi=bufor, rbx=nazwa, rdx=długość)
add_pair:
    mov eax, 16
    call buf_need
    mov [rax], rbx
    mov [rax + 8], rdx
    ret

; imp_math(rsi = nazwa, rdx = długość) -> eax = numer funkcji math (-1: nie ma),
; ecx = 1, gdy dozwolona (import math bez only albo jest na liście only)
imp_math:
    lea rdi, [math_fn]
    call tab_find
    xor ecx, ecx
    test eax, eax
    js .ret
    bt dword [imp_funcs + M_MATH*4], eax
    setc cl
.ret:
    ret

; imp_reset — stan sprzed pierwszego importu (kolejny przebieg kompilacji)
imp_reset:
    xor eax, eax
    mov [imp_mods], rax
    mov [imp_need_base], rax
    mov [imp_funcs], rax
    mov [imp_funcs + 8], rax
    mov [rule_buf + 8], rax
    mov [cmd_buf + 8], rax
    mov [dom_buf + 8], rax
    mov [cmd_all], rax
    mov [dom_all], rax
    mov [place_ptr], rax
    mov [place_len], rax
    mov [cur_mask], rax
    mov [have_dom], rax
    ret

; imp_statement — linia "import ..." (kursor za słowem import; za nim spacja
; i nazwa modułu)
imp_statement:
    push rbx
    push rbp
    push r14
    push r15
    call blank
    mov rbx, r12
    call skip_ident
    mov rbp, r12
    sub rbp, rbx
    lea rdi, [mod_tab]
    mov rsi, rbx
    mov rdx, rbp
    call tab_find
    test eax, eax
    js .bad_module
    mov r14d, eax                   ; moduł
    lea rcx, [mod_pol]
    mov cl, [rcx + r14]
    or [imp_mods], cl
    call at_end
    je .no_place
    movzx eax, byte [r12]
    cmp al, ' '
    je .spaced
    cmp al, 9
    je .spaced
    cmp al, 13
    jne .bad_module_tail
.spaced:
    call blank
    mov qword [place_len], 0
    mov byte [have_dom], 0
    call at_end
    je .no_only
    call at_only
    je .only
    ; folder albo domena
    call tok_place
    mov [place_ptr], rbx
    mov [place_len], rdx
    cmp r14d, M_FILES
    je .place_files
    cmp r14d, M_NET
    jne err_imp_place
    call is_domain
    jne err_imp_domain
    jmp .place_ok
.place_files:
    call check_path
.place_ok:
    call blank
    call at_end
    je .no_only
    call at_only
    jne err_imp_expect_only

    ; --- only a, b, c ---
.only:
    add r12, 4
    call blank
    mov qword [cur_mask], 0
.item:
    call at_end
    je err_imp_list
    cmp r14d, M_COMMANDS
    je .item_cmd
    call tok_place
    test rdx, rdx
    jz err_imp_list
    lea rax, [fn_tabs]
    mov edi, [rax + r14*4]
    lea rax, [mod_tab]
    add rdi, rax
    mov rsi, rbx
    push rdx
    call tab_find
    pop rdx
    test eax, eax
    js .item_unknown
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    or [cur_mask], rax
    jmp .item_next
.item_unknown:
    cmp r14d, M_NET
    jne .bad_fn
    call is_domain
    jne .bad_fn
    lea rdi, [dom_buf]
    call add_pair
    mov byte [have_dom], 1
    jmp .item_next
.item_cmd:
    call tok_place
    test rdx, rdx
    jz err_imp_list
    lea rdi, [cmd_buf]
    call add_pair
.item_next:
    call blank
    AT ','
    jne .list_end
    inc r12
    call blank
    jmp .item
.list_end:
    call end_check
    mov rax, [cur_mask]
    test rax, rax
    jnz .apply
    mov rax, -1                     ; only same domeny / polecenia: funkcje wszystkie
    jmp .apply

.no_place:
    mov qword [place_len], 0
    mov byte [have_dom], 0
.no_only:
    call end_check
    cmp r14d, M_COMMANDS
    jne .all
    mov byte [cmd_all], 1
.all:
    mov rax, -1
.apply:
    lea rcx, [imp_funcs]
    or [rcx + r14*4], eax
    cmp r14d, M_FILES
    je .apply_files
    cmp r14d, M_NET
    jne .ret
    ; net: domena z miejsca, a bez żadnej — wszystkie
    mov rdx, [place_len]
    test rdx, rdx
    jz .net_nodom
    mov rbx, [place_ptr]
    lea rdi, [dom_buf]
    call add_pair
    jmp .ret
.net_nodom:
    cmp byte [have_dom], 0
    jne .ret
    mov byte [dom_all], 1
    jmp .ret
.apply_files:
    ; prawa Landlock: suma praw wybranych funkcji
    mov rdx, LL_ALL_NO_EXEC
    cmp eax, -1
    je .rule
    xor edx, edx
    lea r8, [files_rights]
    xor ecx, ecx
.r_loop:
    bt eax, ecx
    jnc .r_next
    or rdx, [r8 + rcx*8]
.r_next:
    inc ecx
    cmp ecx, 8
    jb .r_loop
.rule:
    push rdx
    lea rdi, [rule_buf]
    mov eax, 24
    call buf_need
    pop rdx
    mov [rax], rdx
    mov rcx, [place_len]
    mov [rax + 16], rcx
    xor edx, edx
    test rcx, rcx
    jz .rule_root
    mov rdx, [place_ptr]
    mov byte [imp_need_base], 1
.rule_root:
    mov [rax + 8], rdx
.ret:
    pop r15
    pop r14
    pop rbp
    pop rbx
    ret

.bad_module_tail:
    ; nazwa z doklejonymi znakami (np. files/dane) — w komunikacie całe słowo
    mov r15, rbx
    call tok_place
    mov rbx, r15
    mov rbp, r12
    sub rbp, rbx
.bad_module:
    lea rdi, [msg_mod1]
    mov esi, msg_mod1_len
    mov rdx, rbx
    mov rcx, rbp
    lea r8, [msg_mod2]
    mov r9d, msg_mod2_len
    jmp die_name
.bad_fn:
    lea rdi, [msg_fn1]
    mov esi, msg_fn1_len
    lea rax, [fn_msgs]
    mov r8d, [rax + r14*8]
    mov r9d, [rax + r14*8 + 4]
    lea rax, [mod_tab]
    add r8, rax
    mov rcx, rdx
    mov rdx, rbx
    jmp die_name

; imp_policy -> eax = przesunięcie opisu uprawnień w stałych obrazu
imp_policy:
    push rbx
    push rbp
    push r12
    ; rozmiar: 8 + na regułę 8 + 2 + ścieżka + 0 (pusta ścieżka to "/")
    mov rbp, [rule_buf + 8]
    mov rbx, [rule_buf]
    xor r12d, r12d
    mov eax, 8
.size:
    cmp r12, rbp
    jae .alloc
    mov rcx, [rbx + r12 + 16]
    test rcx, rcx
    jnz .sz
    inc rcx
.sz:
    lea rax, [rax + rcx + 11]
    add r12, 24
    jmp .size
.alloc:
    mov r12, [const_buf + 8]
    call const_need
    mov rdi, rax
    movzx eax, byte [imp_mods]
    cmp byte [imp_need_base], 0
    je .flags
    or eax, POL_BASE
.flags:
    stosd
    mov rax, rbp
    xor edx, edx
    mov ecx, 24
    div rcx
    stosd
    xor r8d, r8d
.rules:
    cmp r8, rbp
    jae .done
    mov rax, [rbx + r8]
    stosq
    mov rsi, [rbx + r8 + 8]
    mov rcx, [rbx + r8 + 16]
    test rcx, rcx
    jz .root
    lea eax, [ecx + 1]
    stosw
    rep movsb
    jmp .nul
.root:
    mov ax, 2
    stosw
    mov al, '/'
    stosb
.nul:
    xor eax, eax
    stosb
    add r8, 24
    jmp .rules
.done:
    mov eax, r12d
    pop r12
    pop rbp
    pop rbx
    ret

ERR err_imp_char,   "niedozwolony znak w imporcie"
ERR err_imp_place,  "ten moduł nie przyjmuje folderu ani adresu (tylko files i net)"
ERR err_imp_domain, "zły adres (przykład: example.com)"
ERR err_imp_abs,    "folder musi być względny wobec folderu programu, np. ./dane"
ERR err_imp_up,     "folder nie może wychodzić poza folder programu ('..')"
ERR err_imp_expect_only, "oczekiwano 'only' albo końca linii"
ERR err_imp_list,   "po only podaj listę, np. only read, write"
