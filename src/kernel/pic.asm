; =============================================================================
; X86ASMOS - Programmable Interrupt Controller (8259 PIC)
; -----------------------------------------------------------------------------
; Remaps the two cascaded 8259 PICs so that hardware IRQs 0-15 map onto IDT
; vectors 32-47 (instead of colliding with CPU exception vectors 0-31).
;
; Public interface:
;   pic_remap      - remap master/slave to vectors 32/40
;   pic_send_eoi   - EAX = IRQ number (0-15); sends the proper EOI
;   pic_mask       - EAX = IRQ number; masks (disables) it
;   pic_unmask     - EAX = IRQ number; unmasks (enables) it
; =============================================================================

PIC1_COMMAND    equ 0x20
PIC1_DATA       equ 0x21
PIC2_COMMAND    equ 0xA0
PIC2_DATA       equ 0xA1

PIC_EOI         equ 0x20
ICW1_INIT       equ 0x11
ICW4_8086       equ 0x01

; -----------------------------------------------------------------------------
pic_remap:
    push eax
    push edx

    ; Save existing masks.
    in al, PIC1_DATA
    mov [pic1_mask_saved], al
    in al, PIC2_DATA
    mov [pic2_mask_saved], al

    ; ICW1: start initialization sequence.
    mov al, ICW1_INIT
    out PIC1_COMMAND, al
    out PIC2_COMMAND, al

    ; ICW2: vector offsets.
    mov al, 0x20                ; master -> IDT 32
    out PIC1_DATA, al
    mov al, 0x28                ; slave  -> IDT 40
    out PIC2_DATA, al

    ; ICW3: cascade wiring. Master IRQ2 -> slave; slave cascaded to IRQ2.
    mov al, 0x04
    out PIC1_DATA, al
    mov al, 0x02
    out PIC2_DATA, al

    ; ICW4: 8086/88 mode.
    mov al, ICW4_8086
    out PIC1_DATA, al
    out PIC2_DATA, al

    ; Restore masks.
    mov al, [pic1_mask_saved]
    out PIC1_DATA, al
    mov al, [pic2_mask_saved]
    out PIC2_DATA, al

    pop edx
    pop eax
    ret

; -----------------------------------------------------------------------------
; pic_send_eoi - EAX = IRQ number.
; -----------------------------------------------------------------------------
pic_send_eoi:
    push eax
    push edx
    cmp eax, 8
    jb .master
    mov al, PIC_EOI
    out PIC2_COMMAND, al        ; EOI to slave for IRQ 8-15
.master:
    mov al, PIC_EOI
    out PIC1_COMMAND, al
    pop edx
    pop eax
    ret

; -----------------------------------------------------------------------------
; pic_mask - EAX = IRQ number (0-15).
; -----------------------------------------------------------------------------
pic_mask:
    push eax
    push ecx
    push edx
    mov ecx, eax
    mov edx, PIC1_DATA
    cmp ecx, 8
    jb .port_ok
    sub ecx, 8
    mov edx, PIC2_DATA
.port_ok:
    in al, dx
    mov ch, 1
    shl ch, cl
    or al, ch
    out dx, al
    pop edx
    pop ecx
    pop eax
    ret

; -----------------------------------------------------------------------------
; pic_unmask - EAX = IRQ number (0-15).
; -----------------------------------------------------------------------------
pic_unmask:
    push eax
    push ecx
    push edx
    mov ecx, eax
    mov edx, PIC1_DATA
    cmp ecx, 8
    jb .port_ok
    sub ecx, 8
    mov edx, PIC2_DATA
.port_ok:
    in al, dx
    mov ch, 1
    shl ch, cl
    not ch
    and al, ch
    out dx, al
    pop edx
    pop ecx
    pop eax
    ret

; -----------------------------------------------------------------------------
; pic_disable - mask every IRQ (used before disabling interrupts).
; -----------------------------------------------------------------------------
pic_disable:
    push eax
    push edx
    mov al, 0xFF
    out PIC1_DATA, al
    out PIC2_DATA, al
    pop edx
    pop eax
    ret

pic1_mask_saved: db 0
pic2_mask_saved: db 0
