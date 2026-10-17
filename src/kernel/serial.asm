; =============================================================================
; X86ASMOS - Serial Port Logger (COM1, 115200 8N1)
; -----------------------------------------------------------------------------
; The serial logger is the single most important debugging tool in a kernel:
; it lets us trace interrupts, scheduler decisions, and crashes without the
; complications of VGA/vsync. QEMU exposes it with "-serial stdio" or a
; named pipe that can be opened in a terminal.
;
; Public interface:
;   serial_init       - configure COM1 to 115200 8N1
;   serial_putchar    - AL = byte to transmit
;   serial_write      - ESI = NUL-terminated string
;   serial_write_hex  - EAX = value, 8 hex digits
;   serial_newline    - CR + LF
; =============================================================================

SERIAL_PORT     equ 0x3F8        ; COM1 base

; -----------------------------------------------------------------------------
serial_init:
    push eax
    push edx

    mov dx, SERIAL_PORT + 1
    mov al, 0x00                ; disable interrupts
    out dx, al

    mov dx, SERIAL_PORT + 3
    mov al, 0x80                ; enable DLAB
    out dx, al

    mov dx, SERIAL_PORT + 0
    mov al, 0x01                ; divisor low (115200 baud)
    out dx, al
    mov dx, SERIAL_PORT + 1
    mov al, 0x00                ; divisor high
    out dx, al

    mov dx, SERIAL_PORT + 3
    mov al, 0x03                ; 8 data bits, no parity, 1 stop bit
    out dx, al

    mov dx, SERIAL_PORT + 2
    mov al, 0xC7                ; enable FIFO, clear, 14-byte threshold
    out dx, al

    mov dx, SERIAL_PORT + 4
    mov al, 0x0B                ; IRQ enable, RTS/DSR set
    out dx, al

    pop edx
    pop eax
    ret

; -----------------------------------------------------------------------------
serial_putchar:
    push edx
    push eax                    ; save the character (and clobber EAX freely)
    mov dx, SERIAL_PORT + 5
.wait:
    in al, dx
    test al, 0x20              ; transmit holding register empty?
    jz .wait
    mov dx, SERIAL_PORT + 0
    mov eax, [esp]             ; reload saved character
    out dx, al
    pop eax
    pop edx
    ret

; -----------------------------------------------------------------------------
serial_write:
    push eax
    push esi
.loop:
    lodsb
    test al, al
    jz .done
    call serial_putchar
    jmp .loop
.done:
    pop esi
    pop eax
    ret

; -----------------------------------------------------------------------------
serial_newline:
    push eax
    mov al, 0x0D
    call serial_putchar
    mov al, 0x0A
    call serial_putchar
    pop eax
    ret

; -----------------------------------------------------------------------------
serial_write_hex:
    push eax
    push ecx
    push ebx
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
    call serial_putchar
    dec ecx
    jnz .loop
    pop ebx
    pop ecx
    pop eax
    ret
