; elf.asm — zapis skompilowanego programu jako plik wykonywalny ELF64
;
; Plik wynikowy to jeden segment PT_LOAD (R+X) pod 0x400000:
;   nagłówek ELF (64 B) | nagłówek programu (56 B) | kod startowy | dane
; Kod startowy wypisuje dane (wynik programu policzony przy kompilacji)
; jednym write i kończy się exit(0). Nie potrzebuje żadnych bibliotek.
%include "fih.inc"
default rel

global write_elf
extern write_fd, die_noline

%define BASE      0x400000
%define EHDR_SIZE 64
%define PHDR_SIZE 56

section .rodata
msg_create:     db "nie można zapisać pliku wynikowego"
msg_create_len  equ $ - msg_create

; szablon: nagłówki + kod startowy; pola zależne od długości danych
; są uzupełniane w kopii (hdr_buf)
tpl:
    ; --- Elf64_Ehdr ---
    db 0x7f, "ELF", 2, 1, 1, 0      ; 64-bit, little endian, wersja 1, SysV
    times 8 db 0
    dw 2                            ; e_type = ET_EXEC
    dw 0x3e                         ; e_machine = x86-64
    dd 1                            ; e_version
    dq BASE + stub - tpl            ; e_entry
    dq EHDR_SIZE                    ; e_phoff
    dq 0                            ; e_shoff
    dd 0                            ; e_flags
    dw EHDR_SIZE                    ; e_ehsize
    dw PHDR_SIZE                    ; e_phentsize
    dw 1                            ; e_phnum
    dw 64, 0, 0                     ; e_shentsize, e_shnum, e_shstrndx
    ; --- Elf64_Phdr ---
    dd 1                            ; p_type = PT_LOAD
    dd 5                            ; p_flags = R + X
    dq 0                            ; p_offset
    dq BASE                         ; p_vaddr
    dq BASE                         ; p_paddr
filesz:
    dq 0                            ; p_filesz (uzupełniane)
memsz:
    dq 0                            ; p_memsz (uzupełniane)
    dq 0x1000                       ; p_align
    ; --- kod startowy ---
stub:
    mov edi, STDOUT
    lea rsi, [rel tpl_end]
    db 0x48, 0xba                   ; mov rdx, imm64
datalen:
    dq 0                            ;   długość danych (uzupełniane)
.write:
    test rdx, rdx
    jz .ok
    mov eax, SYS_WRITE
    syscall
    cmp rax, -EINTR
    je .write
    test rax, rax
    jle .fail
    add rsi, rax
    sub rdx, rax
    jmp .write
.ok:
    xor edi, edi
    jmp .exit
.fail:
    mov edi, 1
.exit:
    mov eax, SYS_EXIT
    syscall
tpl_end:

TPL_SIZE equ tpl_end - tpl

section .bss
hdr_buf: resb TPL_SIZE
stat2:   resb 144

section .text

; write_elf(rdi=ścieżka wyniku, rsi=dane, rdx=długość danych)
write_elf:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rdi            ; ścieżka
    mov r12, rsi
    mov r13, rdx

    ; kopia szablonu z uzupełnionymi długościami
    push rdi
    lea rsi, [tpl]
    lea rdi, [hdr_buf]
    mov ecx, TPL_SIZE
    rep movsb
    pop rdi
    lea rax, [r13 + TPL_SIZE]
    lea rcx, [hdr_buf]
    mov [rcx + filesz - tpl], rax
    mov [rcx + memsz - tpl], rax
    mov [rcx + datalen - tpl], r13

    mov eax, SYS_OPEN
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0o755
    syscall
    test rax, rax
    js .fail
    mov rbx, rax

    ; r15 = 1, gdy wynik jest zwykłym plikiem (tylko taki wolno usunąć po błędzie)
    xor r15d, r15d
    mov eax, SYS_FSTAT
    mov rdi, rbx
    lea rsi, [stat2]
    syscall
    test rax, rax
    jnz .not_regular
    mov eax, [stat2+24]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .not_regular
    mov r15d, 1
.not_regular:

    ; plik mógł istnieć z innymi prawami — ustawiamy rwxr-xr-x
    mov eax, SYS_FCHMOD
    mov rdi, rbx
    mov esi, 0o755
    syscall

    mov rdi, rbx
    lea rsi, [hdr_buf]
    mov edx, TPL_SIZE
    call write_fd
    test rax, rax
    jnz .write_fail
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call write_fd
    test rax, rax
    jnz .write_fail

    mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    test rax, rax
    js .write_fail_closed

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

    ; nieudany zapis — usuwamy niepełny plik (tylko zwykły plik, nie np. /dev/full)
.write_fail:
    mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
.write_fail_closed:
    test r15d, r15d
    jz .fail
    mov eax, SYS_UNLINK
    mov rdi, r14
    syscall
.fail:
    lea rdi, [msg_create]
    mov esi, msg_create_len
    jmp die_noline
