; =============================================================================
; X86ASMOS - PS/2 Mouse Driver (IRQ12)
; -----------------------------------------------------------------------------
; Initialises the PS/2 auxiliary device and decodes the standard 3-byte mouse
; packet into a screen position and button state.
;
; Public interface:
;   mouse_init    - enable the device and register the IRQ12 handler
;   mouse_handler - IRQ12 handler
;   mouse_x, mouse_y, mouse_buttons - globals
; =============================================================================

mouse_x:        dd 400
mouse_y:        dd 300
mouse_buttons:  dd 0
mouse_cycle:    db 0
mouse_packet:   db 0, 0, 0

; -----------------------------------------------------------------------------
mouse_init:
    push eax
    push ebx

    ; Enable the auxiliary PS/2 device.
    mov al, 0xA8
    out 0x64, al

    ; Enable IRQ12 in the keyboard controller command byte.
    mov al, 0x20
    out 0x64, al
    in al, 0x60
    or al, 0x02
    mov bl, al
    mov al, 0x60
    out 0x64, al
    mov al, bl
    out 0x60, al

    ; Enable mouse data reporting.
    mov al, 0xD4
    out 0x64, al
    mov al, 0xF4
    out 0x60, al

    mov eax, 12
    mov ebx, mouse_handler
    call irq_register
    mov eax, 12
    call pic_unmask

    pop ebx
    pop eax
    ret

; -----------------------------------------------------------------------------
; mouse_handler - IRQ12. Assembles the 3-byte packet.
; -----------------------------------------------------------------------------
mouse_handler:
    push eax
    push ebx

    in al, 0x60

    movzx ebx, byte [mouse_cycle]
    cmp ebx, 0
    je .byte0
    cmp ebx, 1
    je .byte1

    ; --- byte 2 (Y movement) ---
    mov [mouse_packet + 2], al
    call mouse_process
    mov byte [mouse_cycle], 0
    jmp .done

.byte0:
    test al, 0x08                       ; bit 3 must be set (alignment)
    jz .done
    mov [mouse_packet + 0], al
    mov byte [mouse_cycle], 1
    jmp .done

.byte1:
    mov [mouse_packet + 1], al
    mov byte [mouse_cycle], 2

.done:
    pop ebx
    pop eax
    ret

; -----------------------------------------------------------------------------
; mouse_process - decode the packet and update the cursor position.
; -----------------------------------------------------------------------------
mouse_process:
    push eax
    push ebx
    push ecx
    push edx

    movzx eax, byte [mouse_packet + 0]
    and eax, 0x07
    mov [mouse_buttons], eax            ; left/middle/right buttons

    ; X delta (sign-extended).
    movzx ebx, byte [mouse_packet + 1]
    test byte [mouse_packet + 0], 0x10
    jz .x_pos
    or ebx, 0xFFFFFF00
.x_pos:

    ; Y delta (sign-extended).
    movzx ecx, byte [mouse_packet + 2]
    test byte [mouse_packet + 0], 0x20
    jz .y_pos
    or ecx, 0xFFFFFF00
.y_pos:

    ; Update X with clamping.
    mov eax, [mouse_x]
    add eax, ebx
    mov edx, [gfx_width]
    test edx, edx
    jz .no_clamp_x
    cmp eax, 0
    jge .x1
    xor eax, eax
.x1:
    cmp eax, edx
    jl .x_ok
    lea eax, [edx - 1]
.x_ok:
.no_clamp_x:
    mov [mouse_x], eax

    ; Update Y (inverted: mouse reports +Y = up).
    mov eax, [mouse_y]
    sub eax, ecx
    mov edx, [gfx_height]
    test edx, edx
    jz .no_clamp_y
    cmp eax, 0
    jge .y1
    xor eax, eax
.y1:
    cmp eax, edx
    jl .y_ok
    lea eax, [edx - 1]
.y_ok:
.no_clamp_y:
    mov [mouse_y], eax

    pop edx
    pop ecx
    pop ebx
    pop eax
    ret
