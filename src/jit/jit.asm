; =============================================================================
; X86ASMOS - JIT-Compiled Brainfuck Scripting Engine
; -----------------------------------------------------------------------------
; Parses a Brainfuck program and compiles it to native x86 code at runtime.
; The generated code is written into a heap buffer and executed directly (the
; kernel runs in flat 32-bit mode where every mapped page is executable; the
; hardware execute-disable/NX bit is a PAE/64-bit feature and is documented
; in the design notes rather than enforced here).
;
; Brainfuck commands and their native translation (data pointer = ESI):
;   >  inc esi
;   <  dec esi
;   +  inc byte [esi]
;   -  dec byte [esi]
;   .  mov al,[esi] ; call serial_putchar
;   ,  call keyboard_getc ; mov [esi],al
;   [  cmp byte [esi],0 ; jz  <after matching ]
;   ]  cmp byte [esi],0 ; jnz <matching [
;
; Public interface:
;   jit_init - allocate the data tape
;   jit_run  - ESI = Brainfuck program string; compile + execute it
; =============================================================================

JIT_DATA_SIZE equ 30000
JIT_CODE_SIZE equ 65536

jit_data_buffer: dd 0

; -----------------------------------------------------------------------------
jit_init:
    push eax
    mov eax, JIT_DATA_SIZE
    call kmalloc
    mov [jit_data_buffer], eax
    pop eax
    ret

; -----------------------------------------------------------------------------
; jit_run - ESI = Brainfuck source. Compiles it and executes the result.
; -----------------------------------------------------------------------------
jit_run:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp

    ; Allocate a code buffer.
    mov eax, JIT_CODE_SIZE
    call kmalloc
    test eax, eax
    jz .done
    mov ebp, eax                        ; EBP = code buffer

    ; Clear the data tape.
    mov edi, [jit_data_buffer]
    mov ecx, JIT_DATA_SIZE / 4
    xor eax, eax
    rep stosd

    ; Compile.
    mov edi, ebp
    call jit_compile_bf

    ; Execute: data pointer in ESI.
    mov esi, [jit_data_buffer]
    call ebp

    ; Release the code buffer.
    mov eax, ebp
    call kfree

.done:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; jit_compile_bf - ESI = source, EDI = code buffer. Returns EAX = code length.
; Uses the CPU stack as a bracket-match stack (source must be well-formed).
; -----------------------------------------------------------------------------
jit_compile_bf:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp

    mov ebp, edi                        ; code start

.parse:
    lodsb
    test al, al
    jz .done

    cmp al, '>'
    je .inc_ptr
    cmp al, '<'
    je .dec_ptr
    cmp al, '+'
    je .inc_cell
    cmp al, '-'
    je .dec_cell
    cmp al, '.'
    je .output
    cmp al, ','
    je .input
    cmp al, '['
    je .open
    cmp al, ']'
    je .close
    jmp .parse

.inc_ptr:
    mov al, 0x46                        ; inc esi
    stosb
    jmp .parse

.dec_ptr:
    mov al, 0x4E                        ; dec esi
    stosb
    jmp .parse

.inc_cell:
    mov ax, 0x06FE                      ; inc byte [esi]
    stosw
    jmp .parse

.dec_cell:
    mov ax, 0x0EFE                      ; dec byte [esi]
    stosw
    jmp .parse

.output:
    mov al, 0x8A                        ; mov al, [esi]
    stosb
    mov al, 0x06
    stosb
    mov al, 0xBA                        ; mov edx, serial_putchar
    stosb
    mov eax, serial_putchar
    stosd
    mov ax, 0xD2FF                      ; call edx
    stosw
    jmp .parse

.input:
    mov al, 0xBA                        ; mov edx, keyboard_getc
    stosb
    mov eax, keyboard_getc
    stosd
    mov ax, 0xD2FF                      ; call edx
    stosw
    mov ax, 0x0688                      ; mov [esi], al
    stosw
    jmp .parse

.open:
    ; cmp byte [esi], 0
    mov ax, 0x3E80
    stosw
    mov al, 0x00
    stosb
    ; record the rel32 field position of the upcoming jz
    lea edx, [edi + 2]
    push edx
    mov ax, 0x840F                      ; jz rel32 (placeholder)
    stosw
    xor eax, eax
    stosd
    jmp .parse

.close:
    pop ebx                             ; EBX = open jz rel32 field position
    ; cmp byte [esi], 0
    mov ax, 0x3E80
    stosw
    mov al, 0x00
    stosb
    ; jnz: opcode 0F 85 + rel32
    mov ax, 0x850F
    stosw
    ; jnz target = open '[' cmp position = EBX - 5
    mov eax, ebx
    sub eax, 5
    sub eax, edi                        ; - (rel32 field position)
    sub eax, 4                          ; - 4  => target - next_ip
    stosd
    ; patch the open jz: target = current position (after this ']' block)
    mov eax, edi
    sub eax, ebx
    sub eax, 4
    mov [ebx], eax
    jmp .parse

.done:
    mov al, 0xC3                        ; ret
    stosb
    mov eax, edi
    sub eax, ebp                        ; code length

    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
