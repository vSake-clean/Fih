; io.asm — buforowane wyjście i komunikaty błędów (czyste syscalle)
%include "fih.inc"
default rel

%define OUTSZ 65536
%define MAXSEG 32
%define SEG_MEM (1 << 63)       ; znacznik kawałka "fragment bufora wyjścia"
%define HUGE (2 << 20)          ; duża strona
%define SYS_MADVISE 28
%define MADV_HUGEPAGE 14

global write_fd, write_all, out_flush, out_write, out_write_nl, out_byte, out_int, out_int_nl, fmt_int
global die, die_noline, out_to_memory, out_held_write, out_held_len, out_add_raw, out_used
global quiet_errors, child_pids, kill_children, out_to_fixed_memory
global die_name, out_reset, bail_rsp, bail_ip, out_held_stdout
extern cur_line

; Wyjście ma dwa tryby:
;   strumień — bufor 64 KB (outbuf) opróżniany na stdout,
;   pamięć   — wyjście zostaje w pamięci (obuf rośnie albo, w procesie
;              potomnym, ma stałą wielkość) i jest wypisywane na końcu jako
;              lista kawałków: fragmenty obuf i gotowe bufory potomków (par.asm).
; Szybka ścieżka jest ta sama: obuf/ocap wskazują bieżący bufor.

section .bss
obuf:    resq 1             ; początek bieżącego bufora wyjścia (out_reset przy starcie)
optr:    resq 1             ; miejsce następnego zapisu
oend:    resq 1             ; koniec bufora
oend24:  resq 1             ; koniec - 24 (miejsce na liczbę)
outbuf:  resb OUTSZ
direct:  resq 1             ; 1 = tryb pamięci
fixedm:  resq 1             ; 1 = bufor stałej wielkości (nie wolno go powiększać)
segs:    resq 2 * MAXSEG    ; kawałki: dq wskaźnik (albo SEG_MEM | przesunięcie w obuf), dq długość
nseg:    resq 1
seg_start: resq 1           ; początek jeszcze niezamkniętego fragmentu obuf
quiet_errors: resq 1        ; 1 w procesie potomnym: błąd = tylko kod wyjścia 3
child_pids:   resq MAXP     ; procesy potomne (par.asm) do zabicia przy błędzie
bail_rsp:     resq 1        ; != 0: błąd w programie nie kończy fih, tylko wraca
bail_ip:      resq 1        ;   do main (bail_ip, stos bail_rsp) — wtedy program
                            ;   kompiluje comp.asm, który zgłosi błąd sam

section .rodata
msg_prefix_line:     db "fih: błąd w linii "
msg_prefix_line_len  equ $ - msg_prefix_line
msg_prefix:          db "fih: błąd: "
msg_prefix_len       equ $ - msg_prefix
msg_colon:           db ": "
msg_nl:              db 10
align 8
pow10:                              ; 10^0 .. 10^19
%assign i 0
%assign p 1
%rep 20
    dq p
%assign p p * 10
%endrep
digits2:                            ; "00" "01" ... "99"
%assign i 0
%rep 100
    db '0' + i / 10, '0' + i % 10
%assign i i+1
%endrep
msg_wfail:           db "fih: błąd: nie można zapisać wyjścia", 10
msg_wfail_len        equ $ - msg_wfail
msg_nomem:           db "brak pamięci"
msg_nomem_len        equ $ - msg_nomem

section .text

; write_fd(edi=fd, rsi=bufor, rdx=długość) -> rax = 0 albo -errno
; pisze całość, ponawia przy EINTR i krótkim zapisie
write_fd:
    test rdx, rdx
    jz .ok
    mov eax, SYS_WRITE
    syscall
    cmp rax, -EINTR
    je write_fd
    test rax, rax
    jle .err
    add rsi, rax
    sub rdx, rax
    jmp write_fd
.ok:
    xor eax, eax
    ret
.err:
    jnz .ret
    mov rax, -EIO           ; zapis 0 bajtów traktujemy jak błąd
.ret:
    ret

; write_all(edi=fd, rsi=bufor, rdx=długość) — jak write_fd, ale przy błędzie
; wypisuje komunikat i kończy program kodem 1
write_all:
    push rdi
    call write_fd
    pop rdi
    test rax, rax
    jnz .fail
    ret
.fail:
    cmp edi, STDERR
    je .exit                ; stderr też nie działa — tylko kod wyjścia
    mov eax, SYS_WRITE
    mov edi, STDERR
    lea rsi, [msg_wfail]
    mov edx, msg_wfail_len
    syscall
.exit:
    mov eax, SYS_EXIT
    mov edi, 1
    syscall

; set_buf(rdi=bufor, rsi=pojemność, rdx=zajęte bajty) — nowy bieżący bufor
set_buf:
    mov [obuf], rdi
    add rsi, rdi
    mov [oend], rsi
    sub rsi, 24
    mov [oend24], rsi
    add rdx, rdi
    mov [optr], rdx
    ret

; out_used -> rax = zajęta część bieżącego bufora
out_used:
    mov rax, [optr]
    sub rax, [obuf]
    ret

; out_to_memory(rdi=przewidywana długość wyjścia) — od teraz wyjście zostaje
; w pamięci. Bufor jest od razu rezerwowany (bez przydziału stron) i wyrównany
; do 2 MB, żeby jądro mogło użyć dużych stron: mniej błędów stron przy zapisie.
out_to_memory:
    cmp rdi, OUTSZ
    jae .big
    ; mały program: wystarczy stały bufor (gdyby jednak zabrakło miejsca,
    ; out_room przeniesie wyjście do pamięci z mmap)
    lea rdi, [outbuf]
    mov esi, OUTSZ
    xor edx, edx
    call set_buf
    jmp .mode
.big:
    lea rsi, [rdi + OUTSZ + HUGE - 1]
    and rsi, -HUGE
    push rsi
    add rsi, HUGE               ; zapas na wyrównanie
    mov eax, SYS_MMAP
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4095
    jae out_nomem
    add rax, HUGE - 1
    and rax, -HUGE
    mov rdi, rax
    mov rsi, [rsp]
    cmp rsi, 2 * HUGE           ; duże strony tylko dla dużego wyjścia
    jb .no_huge
    mov eax, SYS_MADVISE        ; błąd madvise nie przeszkadza
    mov edx, MADV_HUGEPAGE
    push rdi
    syscall
    pop rdi
.no_huge:
    pop rsi
    xor edx, edx
    call set_buf
.mode:
    xor eax, eax
    mov [nseg], rax
    mov [seg_start], rax
    mov [fixedm], rax
    mov qword [direct], 1
    ret

; out_to_fixed_memory(rdi=bufor, rsi=pojemność) — wyjście do podanego bufora;
; przepełnienie kończy program błędem (w potomku: kodem 3)
out_to_fixed_memory:
    xor edx, edx
    call set_buf
    xor eax, eax
    mov [nseg], rax
    mov [seg_start], rax
    mov qword [fixedm], 1
    mov qword [direct], 1
    ret

; out_reset() — porzuca zebrane wyjście, wraca do strumienia na stdout
out_reset:
    xor eax, eax
    mov [direct], rax
    mov [fixedm], rax
    mov [nseg], rax
    mov [seg_start], rax
    lea rdi, [outbuf]
    mov esi, OUTSZ
    xor edx, edx
    jmp set_buf

; out_room(rsi=potrzebne bajty) — robi miejsce w buforze: w trybie strumienia
; opróżnia go, w trybie pamięci powiększa (mremap); zachowuje rdi, rsi
out_room:
    cmp qword [direct], 0
    jne .mem
    push rdi
    push rsi
    call out_flush
    pop rsi
    pop rdi
    ret
.mem:
    cmp qword [fixedm], 0
    jne out_nomem
    push rdi
    push rsi
    call out_used
    push rax                    ; zajęte bajty
    mov rdx, [oend]
    sub rdx, [obuf]
    add rdx, rdx
    lea rax, [rax + rsi + OUTSZ]
    cmp rdx, rax
    cmovb rdx, rax
    add rdx, 4095
    and rdx, -4096
    push rdx
    lea rax, [outbuf]
    cmp [obuf], rax
    je .from_static
    mov eax, SYS_MREMAP
    mov rdi, [obuf]
    mov rsi, [oend]
    sub rsi, rdi
    mov r10d, MREMAP_MAYMOVE
    syscall
    pop rsi
    pop rdx
    cmp rax, -4095
    jae out_nomem
    mov rdi, rax
    call set_buf
    pop rsi
    pop rdi
    ret
.from_static:                   ; ze stałego bufora: nowa pamięć i kopia
    mov eax, SYS_MMAP
    xor edi, edi
    mov rsi, rdx
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    syscall
    pop rsi
    pop rdx
    cmp rax, -4095
    jae out_nomem
    mov rdi, rax
    push rsi
    push rdi
    lea rsi, [outbuf]
    mov rcx, rdx
    rep movsb
    pop rdi
    pop rsi
    call set_buf
    pop rsi
    pop rdi
    ret

out_nomem:
    xor eax, eax
    mov [direct], rax
    mov rax, [obuf]
    mov [optr], rax
    lea rdi, [msg_nomem]
    mov esi, msg_nomem_len
    jmp die_noline

; out_flush() — w trybie strumienia opróżnia bufor na stdout (w trybie
; pamięci nic nie robi: wyjście czeka na out_held_write)
out_flush:
    cmp qword [direct], 0
    jne .done
    mov rsi, [obuf]
    mov rdx, [optr]
    sub rdx, rsi
    jz .done
    mov [optr], rsi
    push rdi
    mov edi, STDOUT
    call write_all
    pop rdi
.done:
    ret

; out_add_raw(rsi=dane, rdx=długość) — dopisuje gotowy bufor (wynik procesu
; potomnego) do wyjścia bez kopiowania; tylko w trybie pamięci
out_add_raw:
    call close_seg
    mov rax, [nseg]
    cmp rax, MAXSEG
    jae out_nomem
    shl rax, 4
    lea rcx, [segs]
    mov [rcx + rax], rsi
    mov [rcx + rax + 8], rdx
    inc qword [nseg]
    ret

; close_seg — zamyka bieżący fragment obuf jako kawałek wyjścia
close_seg:
    call out_used
    mov rcx, [seg_start]
    cmp rax, rcx
    je .done
    mov [seg_start], rax
    sub rax, rcx                ; długość
    mov r8, [nseg]
    cmp r8, MAXSEG
    jae out_nomem
    shl r8, 4
    lea r9, [segs]
    bts rcx, 63                 ; SEG_MEM | przesunięcie
    mov [r9 + r8], rcx
    mov [r9 + r8 + 8], rax
    inc qword [nseg]
.done:
    ret

; out_held_len() -> rax = długość całego zebranego wyjścia
out_held_len:
    call close_seg
    xor eax, eax
    mov rcx, [nseg]
    lea rdx, [segs]
.loop:
    test rcx, rcx
    jz .done
    add rax, [rdx + 8]
    add rdx, 16
    dec rcx
    jmp .loop
.done:
    ret

; out_held_write(edi=fd) -> rax = 0 albo -errno — zapisuje zebrane wyjście
out_held_write:
    push rbx
    push r12
    push r13
    mov r13d, edi
    call close_seg
    xor ebx, ebx
.loop:
    cmp rbx, [nseg]
    jae .ok
    mov r12, rbx
    shl r12, 4
    lea rax, [segs]
    add r12, rax
    mov rsi, [r12]
    mov rdx, [r12 + 8]
    btr rsi, 63
    jnc .raw
    add rsi, [obuf]
.raw:
    mov edi, r13d
    call write_fd
    test rax, rax
    jnz .ret
    inc rbx
    jmp .loop
.ok:
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    ret

; out_held_stdout() — zapisuje zebrane wyjście na stdout; przy błędzie
; komunikat i kod 1
out_held_stdout:
    mov edi, STDOUT
    call out_held_write
    test rax, rax
    jnz write_all.fail
    ret

; out_write(rdi=dane, rsi=długość)
out_write:
    mov rax, [optr]
    lea rcx, [rax+rsi]
    cmp rcx, [oend]
    jbe .copy
    call out_room
    cmp qword [direct], 0
    jne .copy
    cmp rsi, OUTSZ
    jb .copy
    ; strumień, za duże na bufor — wysyłamy bezpośrednio
    mov rdx, rsi
    mov rsi, rdi
    mov edi, STDOUT
    jmp write_all
.copy:
    mov rax, [optr]
    lea rcx, [rax + rsi]
    mov [optr], rcx
    mov rcx, rsi
    mov rsi, rdi
    mov rdi, rax
    jmp copy_bytes

; out_byte(dil=bajt)
out_byte:
    mov rax, [optr]
    cmp rax, [oend]
    jb .put
    mov esi, 1
    call out_room
    mov rax, [optr]
.put:
    mov [rax], dil
    inc rax
    mov [optr], rax
    ret

; fmt_int(rdi=liczba ze znakiem, rsi=koniec bufora, min. 20 bajtów)
; -> rax = początek zapisanych cyfr (zapis od końca, po 2 cyfry naraz)
fmt_int:
    mov rax, rdi
    mov r8, rdi
    test rax, rax
    jns .pos
    neg rax                 ; INT64_MIN bez znaku daje poprawny moduł
.pos:
    lea r10, [digits2]
    mov r9, 0x28f5c28f5c28f5c3  ; n / 100 = ((n >> 2) * r9) >> 66, bez div
.pair:
    cmp rax, 100
    jb .last
    mov rcx, rax
    shr rax, 2
    mul r9
    shr rdx, 2              ; iloraz
    imul rax, rdx, 100
    sub rcx, rax            ; reszta 0..99
    movzx eax, word [r10 + rcx*2]
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
    test r8, r8
    jns .done
    dec rsi
    mov byte [rsi], '-'
.done:
    mov rax, rsi
    ret

; out_int_nl(rdi=liczba ze znakiem) — wypisuje liczbę i '\n' wprost do bufora:
; najpierw liczba cyfr (bsr * log10(2) + tablica potęg 10), potem cyfry od końca
out_int_nl:
    mov rsi, [optr]         ; miejsce zapisu
    cmp rsi, [oend24]
    jbe .room
    mov esi, 24
    call out_room
    mov rsi, [optr]
.room:
    mov rax, rdi
    test rax, rax
    jns .pos
    mov byte [rsi], '-'
    inc rsi
    neg rax                 ; INT64_MIN bez znaku daje poprawny moduł
.pos:
    cmp rax, 10
    jb .single
    bsr rcx, rax
    inc ecx                 ; liczba bitów
    imul ecx, ecx, 1233     ; * log10(2) * 4096
    shr ecx, 12
    lea rdx, [pow10]
    cmp rax, [rdx + rcx*8]
    sbb rcx, -1             ; liczba cyfr
    lea rdi, [rsi + rcx]    ; tu stanie '\n'
    cmp rax, 100000000
    jae .big
    ; do 8 cyfr: dwie połówki po 4 cyfry liczone niezależnie, 8 znaków
    ; składanych w jednym rejestrze i zapisywanych jednym mov
    mov edx, 0xd1b71759             ; hi = (n * 0xd1b71759) >> 45 = n / 10000
    imul rdx, rax
    shr rdx, 45
    imul r8d, edx, 10000
    sub eax, r8d                    ; lo = n % 10000
    lea r11, [digits2]
    imul r8d, edx, 5243             ; hi / 100 = (hi * 5243) >> 19
    shr r8d, 19
    imul r9d, r8d, 100
    sub edx, r9d                    ; hi % 100
    movzx r8d, word [r11 + r8*2]
    movzx edx, word [r11 + rdx*2]
    shl edx, 16
    or r8d, edx                     ; 4 cyfry hi (pierwsza w najniższym bajcie)
    imul r9d, eax, 5243
    shr r9d, 19                     ; lo / 100
    imul r10d, r9d, 100
    sub eax, r10d                   ; lo % 100
    movzx r9d, word [r11 + r9*2]
    movzx eax, word [r11 + rax*2]
    shl eax, 16
    or eax, r9d
    shl rax, 32
    or rax, r8                      ; 8 cyfr z zerami wiodącymi
    neg ecx
    lea ecx, [rcx*8 + 64]           ; pomijamy 8 - liczba_cyfr zer wiodących
    shr rax, cl
    mov [rsi], rax
    mov byte [rdi], 10
    inc rdi
    mov [optr], rdi
    ret
.big:
    mov byte [rdi], 10
    mov r10, rdi
    lea r11, [digits2]
    mov r9, 0x28f5c28f5c28f5c3  ; n / 100 = ((n >> 2) * r9) >> 66
.pair:
    cmp rax, 100
    jb .last
    mov rcx, rax
    shr rax, 2
    mul r9
    shr rdx, 2
    imul rax, rdx, 100
    sub rcx, rax
    movzx eax, word [r11 + rcx*2]
    sub r10, 2
    mov [r10], ax
    mov rax, rdx
    jmp .pair
.last:
    cmp eax, 10
    jb .one
    movzx eax, word [r11 + rax*2]
    mov [r10 - 2], ax
    jmp .done
.one:
    add al, '0'
    mov [r10 - 1], al
    jmp .done
.single:
    add al, '0'
    mov [rsi], al
    lea rdi, [rsi + 1]
    mov byte [rdi], 10
.done:
    inc rdi
    mov [optr], rdi
    ret

; out_write_nl(rdi=dane, rsi=długość) — jak out_write, z dopisanym '\n'
out_write_nl:
    mov rdx, [optr]
    lea rcx, [rdx + rsi + 1]
    cmp rcx, [oend]
    ja .slow
    mov [optr], rcx
    mov byte [rdx + rsi], 10
    mov rcx, rsi
    mov rsi, rdi
    mov rdi, rdx
    jmp copy_bytes
.slow:
    call out_write
    mov edi, 10
    jmp out_byte

; copy_bytes(rdi=cel, rsi=źródło, rcx=długość) — szybkie kopiowanie krótkich
; fragmentów: nakładające się ładowania zamiast rep movsb (który ma duży
; koszt startu); nigdy nie czyta poza [rsi, rsi+rcx)
copy_bytes:
    cmp rcx, 32
    ja .over32
    cmp rcx, 16
    jae .x16
    cmp rcx, 8
    jae .x8
    cmp rcx, 4
    jae .x4
    test rcx, rcx
    jz .done
    movzx eax, byte [rsi]
    movzx edx, byte [rsi+rcx-1]
    mov [rdi], al
    mov [rdi+rcx-1], dl
    cmp rcx, 3
    jb .done
    movzx eax, byte [rsi+1]
    mov [rdi+1], al
.done:
    ret
.x4:
    mov eax, [rsi]
    mov edx, [rsi+rcx-4]
    mov [rdi], eax
    mov [rdi+rcx-4], edx
    ret
.x8:
    mov rax, [rsi]
    mov rdx, [rsi+rcx-8]
    mov [rdi], rax
    mov [rdi+rcx-8], rdx
    ret
.x16:
    movdqu xmm0, [rsi]
    movdqu xmm1, [rsi+rcx-16]
    movdqu [rdi], xmm0
    movdqu [rdi+rcx-16], xmm1
    ret
.over32:
    cmp rcx, 64
    ja .long
    movdqu xmm0, [rsi]
    movdqu xmm1, [rsi+16]
    movdqu xmm2, [rsi+rcx-32]
    movdqu xmm3, [rsi+rcx-16]
    movdqu [rdi], xmm0
    movdqu [rdi+16], xmm1
    movdqu [rdi+rcx-32], xmm2
    movdqu [rdi+rcx-16], xmm3
    ret
.long:
    rep movsb
    ret

; out_int(rdi=liczba ze znakiem)
out_int:
    sub rsp, 32
    lea rsi, [rsp+32]
    call fmt_int
    lea rsi, [rsp+32]
    sub rsi, rax
    mov rdi, rax
    call out_write
    add rsp, 32
    ret

; kill_children() — zabija procesy potomne, które jeszcze liczą (par.asm)
kill_children:
    push rdi
    push rsi
    lea r8, [child_pids]
    mov r9d, MAXP
.loop:
    mov rdi, [r8]
    test rdi, rdi
    jz .next
    mov eax, SYS_KILL
    mov esi, SIGKILL
    syscall
    mov qword [r8], 0
.next:
    add r8, 8
    dec r9d
    jnz .loop
    pop rsi
    pop rdi
    ret

; die_hook — wspólny początek obsługi błędu
die_hook:
    cmp qword [quiet_errors], 0
    jne .quiet
    jmp kill_children
.quiet:
    mov eax, SYS_EXIT_GROUP
    mov edi, 3
    syscall

; die(rdi=komunikat, rsi=długość) — "fih: błąd w linii N: komunikat", exit 1
die:
    cmp qword [quiet_errors], 0
    jne die_hook.quiet
    cmp qword [bail_rsp], 0
    jne .bail
    call die_hook
    push rdi
    push rsi
    call out_flush
    mov edi, STDERR
    lea rsi, [msg_prefix_line]
    mov edx, msg_prefix_line_len
    call write_all
    sub rsp, 32
    mov rdi, [cur_line]
    lea rsi, [rsp+32]
    call fmt_int
    lea rdx, [rsp+32]
    sub rdx, rax
    mov rsi, rax
    mov edi, STDERR
    call write_all
    add rsp, 32
    mov edi, STDERR
    lea rsi, [msg_colon]
    mov edx, 2
    call write_all
    jmp die_tail
.bail:
    call kill_children
    mov rsp, [bail_rsp]
    mov qword [bail_rsp], 0
    jmp [bail_ip]

; die_name(rdi=część 1, esi=długość, rdx=nazwa, ecx=długość, r8=część 3,
; r9d=długość) — "fih: błąd w linii N: część 1 + nazwa + część 3", exit 1
die_name:
    push r8
    push r9
    push rcx
    push rdx
    push rsi
    push rdi
    call out_flush
    mov edi, STDERR
    lea rsi, [msg_prefix_line]
    mov edx, msg_prefix_line_len
    call write_all
    sub rsp, 32
    mov rdi, [cur_line]
    lea rsi, [rsp+32]
    call fmt_int
    lea rdx, [rsp+32]
    sub rdx, rax
    mov rsi, rax
    mov edi, STDERR
    call write_all
    add rsp, 32
    mov edi, STDERR
    lea rsi, [msg_colon]
    mov edx, 2
    call write_all
    mov edi, STDERR
    pop rsi
    pop rdx
    call write_all
    mov edi, STDERR
    pop rsi
    pop rdx
    call write_all
    jmp die_tail

; die_noline(rdi=komunikat, rsi=długość) — "fih: błąd: komunikat", exit 1
die_noline:
    call die_hook
    push rdi
    push rsi
    call out_flush
    mov edi, STDERR
    lea rsi, [msg_prefix]
    mov edx, msg_prefix_len
    call write_all
die_tail:
    pop rdx
    pop rsi
    mov edi, STDERR
    call write_all
    mov edi, STDERR
    lea rsi, [msg_nl]
    mov edx, 1
    call write_all
    mov eax, SYS_EXIT
    mov edi, 1
    syscall
