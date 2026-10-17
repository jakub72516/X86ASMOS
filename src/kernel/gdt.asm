; =============================================================================
; X86ASMOS - Global Descriptor Table
; -----------------------------------------------------------------------------
; The kernel replaces the Stage 2 loader's minimal GDT with a full one that
; includes ring-3 code/data segments and a Task State Segment. The layout:
;
;   selector   descriptor
;   0x00       null
;   0x08       kernel code (ring 0)
;   0x10       kernel data (ring 0)
;   0x18       user code   (ring 3, RPL 3 = 0x1B)
;   0x20       user data   (ring 3, RPL 3 = 0x23)
;   0x28       TSS
;
; Public interface:
;   gdt_install - load GDTR, reload segment registers, load the TSS
; =============================================================================

KERNEL_CS   equ 0x08
KERNEL_DS   equ 0x10
USER_CS     equ 0x18
USER_DS     equ 0x20
TSS_SELECTOR equ 0x28

; -----------------------------------------------------------------------------
; gdt_install - install and activate the GDT and TSS.
; -----------------------------------------------------------------------------
gdt_install:
    push eax
    push ebx

    ; Set the TSS ring-0 stack so the CPU knows where to put the stack when
    ; it transitions from ring 3 to ring 0 (interrupts / syscalls).
    mov dword [tss + 0x04], KERNEL_STACK_TOP   ; esp0
    mov dword [tss + 0x08], KERNEL_DS          ; ss0

    ; Fill the TSS descriptor's base address at runtime (NASM cannot apply
    ; bitwise operators to a relocatable symbol).
    mov eax, tss
    mov word [gdt + 0x28 + 2], ax      ; base bits 0-15
    mov ebx, eax
    shr ebx, 16
    mov byte [gdt + 0x28 + 4], bl      ; base bits 16-23
    shr ebx, 8
    mov byte [gdt + 0x28 + 7], bl      ; base bits 24-31

    lgdt [gdt_ptr]

    ; Reload data segment registers.
    mov ax, KERNEL_DS
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Reload CS via a far jump.
    jmp KERNEL_CS:.reload
.reload:
    ; Load the TSS.
    mov ax, TSS_SELECTOR
    ltr ax

    pop ebx
    pop eax
    ret

; -----------------------------------------------------------------------------
; Task State Segment (104 bytes for a 32-bit TSS). Defined before the GDT so
; its address is known when the TSS descriptor is assembled.
; -----------------------------------------------------------------------------
align 4
tss:
    dd 0            ; 0x00 prev task link
    dd 0            ; 0x04 esp0
    dd 0            ; 0x08 ss0
    dd 0            ; 0x0C esp1
    dd 0            ; 0x10 ss1
    dd 0            ; 0x14 esp2
    dd 0            ; 0x18 ss2
    dd 0            ; 0x1C cr3
    dd 0            ; 0x20 eip
    dd 0            ; 0x24 eflags
    dd 0            ; 0x28 eax
    dd 0            ; 0x2C ecx
    dd 0            ; 0x30 edx
    dd 0            ; 0x34 ebx
    dd 0            ; 0x38 esp
    dd 0            ; 0x3C ebp
    dd 0            ; 0x40 esi
    dd 0            ; 0x44 edi
    dd 0            ; 0x48 es
    dd 0            ; 0x4C cs
    dd 0            ; 0x50 ss
    dd 0            ; 0x54 ds
    dd 0            ; 0x58 fs
    dd 0            ; 0x5C gs
    dd 0            ; 0x60 ldt
    dw 0            ; 0x64 trap flag / iomap base
    dw 0xFFFF       ; 0x66 iomap base = 0xFFFF (no I/O bitmap)

; -----------------------------------------------------------------------------
; GDT entries (flat 4 GiB model).
; -----------------------------------------------------------------------------
align 8
gdt:
    ; null
    dq 0
    ; 0x08 kernel code
    dw 0xFFFF, 0x0000, 0x9A00, 0x00CF
    ; 0x10 kernel data
    dw 0xFFFF, 0x0000, 0x9200, 0x00CF
    ; 0x18 user code
    dw 0xFFFF, 0x0000, 0xFA00, 0x00CF
    ; 0x20 user data
    dw 0xFFFF, 0x0000, 0xF200, 0x00CF
    ; 0x28 TSS (limit 0x67 = 103; base filled at runtime by gdt_install)
    dw 0x0067
    dw 0
    db 0
    db 0x89                             ; present, 32-bit available TSS, DPL 0
    db 0x40
    db 0
gdt_end:

gdt_ptr:
    dw gdt_end - gdt - 1
    dd gdt

