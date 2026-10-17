; =============================================================================
; X86ASMOS - VGA Text Mode Driver
; -----------------------------------------------------------------------------
; Provides early-boot console output through the 80x25 text-mode framebuffer
; at 0xB8000. All routines preserve all registers they do not document.
;
; Public interface:
;   vga_init          - clear screen, home cursor
;   vga_clear         - clear screen, home cursor
;   vga_putchar       - AL = character (interprets '\n', '\r', '\t')
;   vga_print         - ESI = NUL-terminated string
;   vga_print_hex     - EAX = value, prints 8 hex digits
;   vga_newline       - CR + LF
;   vga_set_cursor    - DH = row, DL = col
; =============================================================================

VGA_ADDR        equ 0xB8000
VGA_WIDTH       equ 80
VGA_HEIGHT      equ 25
VGA_ATTR        equ 0x0F        ; white on black

; Cursor state.
vga_row:        db 0
vga_col:        db 0

; -----------------------------------------------------------------------------
vga_init:
    call vga_clear
    ret

; -----------------------------------------------------------------------------
vga_clear:
    pusha
    mov edi, VGA_ADDR
    mov ax, (VGA_ATTR << 8) | ' '
    mov ecx, VGA_WIDTH * VGA_HEIGHT
    rep stosw
    mov byte [vga_row], 0
    mov byte [vga_col], 0
    call vga_update_cursor
    popa
    ret

; -----------------------------------------------------------------------------
; vga_putchar - write one character in AL at the cursor, advancing it.
; -----------------------------------------------------------------------------
vga_putchar:
    cmp al, 0x0A
    je vga_newline
    cmp al, 0x0D
    je .carriage_return
    cmp al, 0x09
    je .tab
    ; fall through to store a printable character
    push eax
    call .store
    pop eax
    ret
.carriage_return:
    mov byte [vga_col], 0
    call vga_update_cursor
    ret
.tab:
    mov al, [vga_col]
    add al, 8
    and al, 0xF8
    mov [vga_col], al
    call vga_update_cursor
    ret
.store:
    ; Character is in AL (via pushed EAX). Compute cell address from cursor.
    push eax                        ; keep character byte safe
    movzx eax, byte [vga_row]
    movzx ecx, byte [vga_col]
    imul eax, VGA_WIDTH
    add eax, ecx
    shl eax, 1
    add eax, VGA_ADDR
    mov edi, eax
    pop eax                         ; EAX = character (low byte)
    mov ah, VGA_ATTR
    mov word [edi], ax              ; write char + attribute
    ; advance column, wrapping if needed
    mov al, [vga_col]
    inc al
    cmp al, VGA_WIDTH
    jb .nowrap
    call vga_newline
    ret
.nowrap:
    mov [vga_col], al
    call vga_update_cursor
    ret

; -----------------------------------------------------------------------------
vga_newline:
    pusha
    mov byte [vga_col], 0
    mov al, [vga_row]
    inc al
    cmp al, VGA_HEIGHT
    jb .no_scroll
    call vga_scroll
    mov al, VGA_HEIGHT - 1
.no_scroll:
    mov [vga_row], al
    call vga_update_cursor
    popa
    ret

; -----------------------------------------------------------------------------
vga_scroll:
    pusha
    mov esi, VGA_ADDR + VGA_WIDTH * 2
    mov edi, VGA_ADDR
    mov ecx, (VGA_WIDTH * (VGA_HEIGHT - 1) * 2) / 4
    rep movsd
    mov edi, VGA_ADDR + VGA_WIDTH * (VGA_HEIGHT - 1) * 2
    mov ax, (VGA_ATTR << 8) | ' '
    mov ecx, VGA_WIDTH
    rep stosw
    popa
    ret

; -----------------------------------------------------------------------------
vga_print:
    pusha
.loop:
    lodsb
    test al, al
    jz .done
    call vga_putchar
    jmp .loop
.done:
    popa
    ret

; -----------------------------------------------------------------------------
vga_print_hex:
    pusha
    mov ecx, 8
    mov ebx, eax
.loop:
    rol ebx, 4
    mov eax, ebx
    and eax, 0x0F
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp .out
.digit:
    add al, '0'
.out:
    call vga_putchar
    dec ecx
    jnz .loop
    popa
    ret

; -----------------------------------------------------------------------------
vga_set_cursor:
    push eax
    mov [vga_row], dh
    mov [vga_col], dl
    call vga_update_cursor
    pop eax
    ret

; -----------------------------------------------------------------------------
vga_update_cursor:
    push eax
    push edx
    push ebx
    movzx eax, byte [vga_row]
    movzx ecx, byte [vga_col]
    imul eax, VGA_WIDTH
    add eax, ecx                    ; EAX = linear cursor offset
    mov bx, ax                      ; stash position (BH=high, BL=low)
    mov dx, 0x03D4
    mov al, 0x0E
    out dx, al
    mov dx, 0x03D5
    mov al, bh                      ; high byte
    out dx, al
    mov dx, 0x03D4
    mov al, 0x0F
    out dx, al
    mov dx, 0x03D5
    mov al, bl                      ; low byte
    out dx, al
    pop ebx
    pop edx
    pop eax
    ret
