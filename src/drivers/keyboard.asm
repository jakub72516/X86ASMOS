; =============================================================================
; X86ASMOS - PS/2 Keyboard Driver (IRQ1, scancode set 1)
; -----------------------------------------------------------------------------
; Translates key-down scancodes to ASCII, tracks the shift state, and stores
; characters in a 256-byte circular buffer.
;
; Public interface:
;   keyboard_init    - register the IRQ1 handler and unmask it
;   keyboard_handler - IRQ1 handler
;   keyboard_getc    - EAX = next buffered character (0 if none)
; =============================================================================

KB_BUFFER_SIZE equ 256

kb_buffer:      times KB_BUFFER_SIZE db 0
kb_head:        dd 0
kb_tail:        dd 0
kb_shift:       db 0

; -----------------------------------------------------------------------------
keyboard_init:
    push eax
    push ebx
    mov eax, 1                          ; IRQ1
    mov ebx, keyboard_handler
    call irq_register
    mov eax, 1
    call pic_unmask
    pop ebx
    pop eax
    ret

; -----------------------------------------------------------------------------
; keyboard_handler - IRQ1.
; -----------------------------------------------------------------------------
keyboard_handler:
    push eax
    push ebx

    in al, 0x60                         ; scancode

    test al, 0x80                       ; key release?
    jnz .release

    ; --- key down ---
    cmp al, 0x2A                        ; left shift
    je .shift_down
    cmp al, 0x36                        ; right shift
    je .shift_down
    cmp al, 0x3A                        ; caps lock (toggle)
    je .caps

    movzx ebx, al
    mov al, [scancode_table + ebx]      ; base ASCII
    test al, al
    jz .done

    ; Apply shift/caps to letters.
    cmp al, 'a'
    jb .not_letter
    cmp al, 'z'
    ja .not_letter
    ; letter: uppercase if shift xor caps
    mov bl, [kb_shift]
    xor bl, [kb_caps]
    test bl, bl
    jz .not_letter
    sub al, 0x20                        ; uppercase
.not_letter:
    call kb_push
    jmp .done

.shift_down:
    mov byte [kb_shift], 1
    jmp .done

.caps:
    xor byte [kb_caps], 1
    jmp .done

.release:
    and al, 0x7F
    cmp al, 0x2A
    je .shift_up
    cmp al, 0x36
    je .shift_up
    jmp .done
.shift_up:
    mov byte [kb_shift], 0

.done:
    pop ebx
    pop eax
    ret

; -----------------------------------------------------------------------------
; kb_push - AL = character; store in the circular buffer (drop if full).
; -----------------------------------------------------------------------------
kb_push:
    push ebx
    push ecx
    movzx eax, al
    mov ebx, [kb_head]
    mov ecx, ebx
    inc ecx
    and ecx, KB_BUFFER_SIZE - 1
    cmp ecx, [kb_tail]                  ; full?
    je .done
    mov [kb_buffer + ebx], al
    mov [kb_head], ecx
.done:
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; keyboard_getc - returns EAX = next character (0 if the buffer is empty).
; -----------------------------------------------------------------------------
keyboard_getc:
    push ebx
    xor eax, eax
    mov ebx, [kb_tail]
    cmp ebx, [kb_head]                  ; empty?
    je .done
    movzx eax, byte [kb_buffer + ebx]
    inc ebx
    and ebx, KB_BUFFER_SIZE - 1
    mov [kb_tail], ebx
.done:
    pop ebx
    ret

kb_caps: db 0

; -----------------------------------------------------------------------------
; Scancode set 1 -> ASCII (base, unshifted). 0 = unmapped.
; -----------------------------------------------------------------------------
scancode_table:
    db 0, 0, '1','2','3','4','5','6','7','8','9','0','-','=',0x08,0x09 ; 0x00-0x0F
    db 'q','w','e','r','t','y','u','i','o','p','[',']',0x0A,0,'a','s'  ; 0x10-0x1F
    db 'd','f','g','h','j','k','l',';',0x27,'`',0, 0x5C,'z','x','c','v' ; 0x20-0x2F
    db 'b','n','m',',','.','/',0, 0, 0, ' ',0,0,0,0,0,0               ; 0x30-0x3F
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0                               ; 0x40-0x4F
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0                               ; 0x50-0x5F
