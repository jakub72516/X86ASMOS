; =============================================================================
; X86ASMOS - Interrupt Descriptor Table & ISR Stubs
; -----------------------------------------------------------------------------
; Installs an IDT covering CPU exceptions (0-31), remapped hardware IRQs
; (32-47), and the system-call gate (0x80). Every vector funnels through a
; common stub that builds a register frame on the stack, then dispatches.
;
; Register frame layout (offsets from the frame base pointer, which points at
; the pushed GS value):
;   REG_GS=0 REG_FS=4 REG_ES=8 REG_DS=12
;   REG_EDI=16 REG_ESI=20 REG_EBP=24 REG_ESP=28
;   REG_EBX=32 REG_EDX=36 REG_ECX=40 REG_EAX=44
;   REG_INTNUM=48 REG_ERR=52 REG_EIP=56 REG_CS=60 REG_EFLAGS=64
;
; Public interface:
;   idt_install      - fill the IDT, load IDTR
;   idt_set_gate     - EAX=vector, EBX=handler, CL=attributes
;   irq_register     - EAX=irq, EBX=handler; installs an IRQ handler
; =============================================================================

REG_GS       equ 0
REG_FS       equ 4
REG_ES       equ 8
REG_DS       equ 12
REG_EDI      equ 16
REG_ESI      equ 20
REG_EBP      equ 24
REG_ESP      equ 28
REG_EBX      equ 32
REG_EDX      equ 36
REG_ECX      equ 40
REG_EAX      equ 44
REG_INTNUM   equ 48
REG_ERR      equ 52
REG_EIP      equ 56
REG_CS       equ 60
REG_EFLAGS   equ 64

; --- ISR stub macros -------------------------------------------------------
%macro ISR_NOERR 1
isr %+ %1:
    push dword 0
    push dword %1
    jmp isr_common
%endmacro

%macro ISR_ERR 1
isr %+ %1:
    push dword %1
    jmp isr_common
%endmacro

; --- Instantiate exception stubs (0-31) ------------------------------------
ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_NOERR 21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_NOERR 29
ISR_NOERR 30
ISR_NOERR 31

; --- Instantiate IRQ stubs (32-47) -----------------------------------------
%assign irq_vec 32
%rep 16
isr %+ irq_vec:
    push dword 0
    push dword irq_vec
    jmp isr_common
%assign irq_vec irq_vec + 1
%endrep

; --- Syscall stub (0x80) ----------------------------------------------------
isr_syscall:
    push dword 0
    push dword 0x80
    jmp isr_common

; --- Yield stub (0x81) ------------------------------------------------------
isr_yield:
    push dword 0
    push dword 0x81
    jmp isr_common

; --- Table of the first 48 handlers ----------------------------------------
isr_table:
%assign i 0
%rep 48
    dd isr %+ i
%assign i i+1
%endrep

; -----------------------------------------------------------------------------
; idt_install
; -----------------------------------------------------------------------------
idt_install:
    pusha
    xor ecx, ecx
.set:
    mov eax, ecx
    mov ebx, [isr_table + ecx * 4]
    push ecx
    mov cl, 0x8E                    ; ring 0 interrupt gate
    call idt_set_gate
    pop ecx
    inc ecx
    cmp ecx, 48
    jb .set

    ; Syscall gate (ring 3 accessible).
    mov eax, 0x80
    mov ebx, isr_syscall
    mov cl, 0xEE
    call idt_set_gate

    ; Yield gate (ring 3 accessible).
    mov eax, 0x81
    mov ebx, isr_yield
    mov cl, 0xEE
    call idt_set_gate

    lidt [idt_ptr]
    popa
    ret

; -----------------------------------------------------------------------------
; idt_set_gate - EAX=vector, EBX=handler address, CL=attributes byte.
; -----------------------------------------------------------------------------
idt_set_gate:
    push edi
    push edx
    mov edi, idt
    mov edx, eax
    shl edx, 3                      ; vector * 8
    add edi, edx
    mov word [edi], bx              ; handler offset bits 0-15
    mov word [edi + 2], KERNEL_CS   ; code selector
    mov byte [edi + 4], 0           ; IST
    mov byte [edi + 5], cl          ; attributes
    shr ebx, 16
    mov word [edi + 6], bx          ; handler offset bits 16-31
    pop edx
    pop edi
    ret

; -----------------------------------------------------------------------------
; isr_common - the funnel for every interrupt.
; -----------------------------------------------------------------------------
isr_common:
    pusha
    push ds
    push es
    push fs
    push gs
    mov ax, KERNEL_DS
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    mov esi, esp                    ; ESI = frame pointer
    mov eax, [esi + REG_INTNUM]

    cmp eax, 0x80
    je .syscall
    cmp eax, 0x81
    je .yield
    cmp eax, 32
    jb .exception
    call irq_dispatch
    jmp .epilogue

.yield:
    jmp yield_handler                ; tail jump: ESP stays at the frame base

.syscall:
    call syscall_handler
    jmp .epilogue

.exception:
    call exception_handler

.epilogue:
isr_restore:
    pop gs
    pop fs
    pop es
    pop ds
    popa
    add esp, 8                      ; drop int number + error code
    iret

; -----------------------------------------------------------------------------
; irq_dispatch - ESI = frame. Runs a registered handler (if any) then EOI.
; -----------------------------------------------------------------------------
irq_dispatch:
    mov eax, [esi + REG_INTNUM]
    sub eax, 32                     ; EAX = IRQ number
    push eax
    cmp eax, 15
    ja .send_eoi
    mov edx, [irq_handlers + eax * 4]
    test edx, edx
    jz .send_eoi
    call edx                        ; handler(EAX=irq, ESI=frame)
.send_eoi:
    pop eax
    call pic_send_eoi
    ret

; -----------------------------------------------------------------------------
; irq_register - EAX=irq, EBX=handler address.
; -----------------------------------------------------------------------------
irq_register:
    mov [irq_handlers + eax * 4], ebx
    ret

; -----------------------------------------------------------------------------
; exception_handler - ESI = frame. Prints a diagnostic and halts.
; -----------------------------------------------------------------------------
exception_handler:
    mov edi, esi                    ; EDI = frame (ESI is reused for strings)

    mov esi, msg_exc
    call vga_print
    call serial_write

    mov eax, [edi + REG_INTNUM]
    call vga_print_hex
    call serial_write_hex

    mov esi, msg_exc_err
    call vga_print
    call serial_write
    mov eax, [edi + REG_ERR]
    call vga_print_hex
    call serial_write_hex

    mov esi, msg_exc_eip
    call vga_print
    call serial_write
    mov eax, [edi + REG_EIP]
    call vga_print_hex
    call serial_write_hex

    mov esi, msg_exc_halting
    call vga_print
    call serial_write

    cli
.halt:
    hlt
    jmp .halt

msg_exc:         db "EXC ", 0
msg_exc_err:     db " err ", 0
msg_exc_eip:     db " eip ", 0
msg_exc_halting: db " halting", 0x0A, 0

; -----------------------------------------------------------------------------
; IRQ handler table (16 entries; zero = no handler).
; -----------------------------------------------------------------------------
align 4
irq_handlers:
    times 16 dd 0

; -----------------------------------------------------------------------------
; IDT storage.
; -----------------------------------------------------------------------------
align 8
idt:
    times 256 * 8 db 0
idt_end:

idt_ptr:
    dw idt_end - idt - 1
    dd idt
