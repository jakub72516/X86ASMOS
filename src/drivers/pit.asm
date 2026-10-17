; =============================================================================
; X86ASMOS - Programmable Interval Timer (8253/8254 PIT)
; -----------------------------------------------------------------------------
; Programs PIT channel 0 in square-wave mode at ~100 Hz to drive the
; pre-emptive scheduler. Each tick raises IRQ0, which is remapped to IDT
; vector 32.
;
; Public interface:
;   pit_init - program channel 0 and register the timer handler
; =============================================================================

PIT_FREQUENCY equ 100
PIT_DIVISOR   equ 1193182 / PIT_FREQUENCY

; -----------------------------------------------------------------------------
pit_init:
    push eax
    push edx

    mov dx, 0x43
    mov al, 0x36                    ; channel 0, lo/hi byte, mode 3, binary
    out dx, al

    mov dx, 0x40
    mov ax, PIT_DIVISOR
    out dx, al                      ; divisor low byte
    mov al, ah
    out dx, al                      ; divisor high byte

    pop edx
    pop eax
    ret
