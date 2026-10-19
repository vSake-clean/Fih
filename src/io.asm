; io.asm — buforowane wyjście i komunikaty błędów (czyste syscalle)
%include "fih.inc"
default rel

%define OUTSZ 65536

global write_fd, write_all, out_flush, out_write, out_write_nl, out_byte, out_int, out_int_nl, fmt_int
global die, die_noline, out_to_memory, mem_ptr, mem_len
global out_raw, quiet_errors, child_pids, kill_children, out_to_fixed_memory
global die_name, out_reset, bail_rsp, bail_ip
extern cur_line

section .bss
outbuf:  resb OUTSZ
outlen:  resq 1
to_mem:  resq 1             ; 1 = wyjście trafia do pamięci (tryb build)
mem_ptr: resq 1
mem_len: resq 1
mem_cap: resq 1
mem_fixed: resq 1           ; 1 = bufor stałej wielkości (nie wolno go powiększać)
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

; out_to_memory() — od teraz wyjście programu zbierane jest w pamięci
; (mem_ptr/mem_len) zamiast trafiać na stdout
out_to_memory:
    mov qword [to_mem], 1
    ret

; out_to_fixed_memory(rdi=bufor, rsi=pojemność) — wyjście do podanego bufora;
; przepełnienie kończy program błędem (w potomku: kodem 3)
out_to_fixed_memory:
    mov qword [to_mem], 1
    mov [mem_ptr], rdi
    mov [mem_cap], rsi
    mov qword [mem_len], 0
    mov qword [mem_fixed], 1
    ret

; out_raw/sink(rsi=dane, rdx=długość) — wysyła gotowe bajty na stdout albo
; do pamięci, z pominięciem bufora (wywołujący najpierw robi out_flush)
out_raw:
sink:
    cmp qword [to_mem], 0
    jne mem_append
    mov edi, STDOUT
    jmp write_all

; mem_append(rsi=dane, rdx=długość) — dopisuje do rosnącego bufora (mmap/mremap)
mem_append:
    mov rax, [mem_len]
    add rax, rdx
    cmp rax, [mem_cap]
    jbe .copy
    cmp qword [mem_fixed], 0
    jne .nomem
    push rsi
    push rdx
    push r12
    mov r12, [mem_cap]
    shl r12, 1
    cmp r12, rax
    cmovb r12, rax
    mov ecx, 1 << 20
    cmp r12, rcx
    cmovb r12, rcx
    add r12, 4095
    and r12, -4096
    mov rdi, [mem_ptr]
    test rdi, rdi
    jz .fresh
    mov eax, SYS_MREMAP
    mov rsi, [mem_cap]
    mov rdx, r12
    mov r10d, MREMAP_MAYMOVE
    syscall
    jmp .check
.fresh:
    mov eax, SYS_MMAP
    xor edi, edi
    mov rsi, r12
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    syscall
.check:
    cmp rax, -4095
    jae .nomem
    mov [mem_ptr], rax
    mov [mem_cap], r12
    pop r12
    pop rdx
    pop rsi
.copy:
    mov rdi, [mem_ptr]
    add rdi, [mem_len]
    mov rcx, rdx
    rep movsb
    add [mem_len], rdx
    ret
.nomem:
    mov qword [to_mem], 0
    mov qword [outlen], 0
    lea rdi, [msg_nomem]
    mov esi, msg_nomem_len
    jmp die_noline

; out_flush() — opróżnia bufor wyjścia
out_flush:
    mov rdx, [outlen]
    test rdx, rdx
    jz .done
    lea rsi, [outbuf]
    call sink
    mov qword [outlen], 0
.done:
    ret

; out_write(rdi=dane, rsi=długość)
out_write:
    mov rax, [outlen]
    lea rcx, [rax+rsi]
    cmp rcx, OUTSZ
    jbe .copy
    push rdi
    push rsi
    call out_flush
    pop rsi
    pop rdi
    cmp rsi, OUTSZ
    jb .copy
    ; za duże na bufor — wysyłamy bezpośrednio
    mov rdx, rsi
    mov rsi, rdi
    jmp sink
.copy:
    mov rax, [outlen]
    mov rcx, rsi
    add [outlen], rsi
    mov rsi, rdi
    lea rdi, [outbuf]
    add rdi, rax
    jmp copy_bytes

; out_byte(dil=bajt)
out_byte:
    mov rax, [outlen]
    cmp rax, OUTSZ
    jb .put
    push rdi
    call out_flush
    pop rdi
    xor eax, eax
.put:
    lea rcx, [outbuf]
    mov [rcx+rax], dil
    inc rax
    mov [outlen], rax
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
    mov rax, [outlen]
    cmp rax, OUTSZ - 24
    jbe .room
    push rdi
    call out_flush
    pop rdi
    xor eax, eax
.room:
    lea rsi, [outbuf]
    add rsi, rax            ; miejsce zapisu
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
    lea rax, [outbuf]
    sub rdi, rax
    inc rdi
    mov [outlen], rdi
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
    lea rax, [outbuf]
    sub rdi, rax
    inc rdi
    mov [outlen], rdi
    ret

; out_write_nl(rdi=dane, rsi=długość) — jak out_write, z dopisanym '\n'
out_write_nl:
    mov rax, [outlen]
    lea rcx, [rax + rsi + 1]
    cmp rcx, OUTSZ
    ja .slow
    mov [outlen], rcx
    lea rdx, [outbuf]
    add rdx, rax
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

; out_reset() — porzuca zebrane wyjście, od teraz wyjście na stdout
out_reset:
    xor eax, eax
    mov [to_mem], rax
    mov [outlen], rax
    mov [mem_len], rax
    ret

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
