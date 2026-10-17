; =============================================================================
; X86ASMOS - Kernel Entry Point
; -----------------------------------------------------------------------------
; Entry state (from Stage 2 loader):
;   ESI = linear address of the boot information block (0x5000)
;   DL  = BIOS boot drive number
;   Segments: flat ring-0 data; CS = 0x08
;   Interrupts disabled, paging not yet enabled
;
; This file is assembled as a flat binary linked to 0x100000 and includes the
; other kernel modules (via %include) to form a single image.
; =============================================================================

BITS 32
ORG 0x100000

; --- Memory layout ----------------------------------------------------------
KERNEL_STACK_TOP equ 0x90000         ; top of the kernel/boot-task stack

section .text

global _start
_start:
    mov esp, KERNEL_STACK_TOP

    mov [boot_info_ptr], esi
    mov [boot_drive], dl

    call serial_init
    call vga_init

    mov esi, msg_banner
    call vga_print
    call serial_write

    ; Validate the boot information block.
    mov esi, [boot_info_ptr]
    cmp dword [esi], 0x41534F53
    jne .bad_bootinfo

    ; --- Memory manager, GDT/IDT, interrupts --------------------------------
    call gdt_install

    mov esi, [boot_info_ptr]
    call pmm_init

    call paging_init

    call kmalloc_init

    call gfx_init                       ; graphics (needs paging + heap)

    call jit_init

    call fat32_init                     ; filesystem (needs heap + ATA)

    call pic_remap
    call idt_install

    ; --- Scheduler + timer ---------------------------------------------------
    call scheduler_init

    call pit_init

    mov eax, 0                          ; IRQ0
    mov ebx, timer_handler
    call irq_register

    mov eax, 0                          ; unmask the timer IRQ
    call pic_unmask

    ; --- Input devices --------------------------------------------------------
    call keyboard_init
    call mouse_init

    ; --- Spawn demo tasks -----------------------------------------------------
    mov ebx, task_worker
    mov ecx, 'A'
    call task_create

    mov ebx, task_worker
    mov ecx, 'B'
    call task_create

    mov ebx, task_ipc
    xor ecx, ecx
    call task_create
    mov [ipc_pid], eax                  ; remember the IPC task's pid

    mov ebx, task_jit
    xor ecx, ecx
    call task_create

    mov ebx, task_music
    xor ecx, ecx
    call task_create

    mov ebx, task_fs
    xor ecx, ecx
    call task_create

    mov ebx, task_net
    xor ecx, ecx
    call task_create

    mov ebx, task_syscall
    xor ecx, ecx
    call task_create

    mov esi, msg_ready
    call vga_print
    call serial_write

    sti

    ; --- Boot task becomes the idle/GUI/IPC-producer loop. It never sleeps,
    ; so the run queue always has at least one ready task. -------------------
.idle:
    ; Redraw the desktop at ~10 Hz.
    mov eax, [tick_count]
    sub eax, [last_render_tick]
    cmp eax, 10
    jb .no_render
    mov eax, [tick_count]
    mov [last_render_tick], eax
    call gui_render
.no_render:

    ; Send an IPC message every 50 ticks.
    mov eax, [tick_count]
    sub eax, [last_ipc_tick]
    cmp eax, 50
    jb .no_ipc
    mov eax, [tick_count]
    mov [last_ipc_tick], eax
    inc dword [idle_counter]
    mov eax, [ipc_pid]
    mov ebx, [idle_counter]
    call ipc_send                       ; send a counter message to the IPC task
.no_ipc:

    ; Echo any typed characters to the serial console (input demo).
    call keyboard_getc
    test eax, eax
    jz .no_key
    call serial_putchar
    cmp eax, 0x0A
    jne .no_key
    mov al, 0x0D
    call serial_putchar
.no_key:
    hlt
    jmp .idle

.bad_bootinfo:
    mov esi, msg_badinfo
    call vga_print
    call serial_write
    cli
    hlt
    jmp .bad_bootinfo

; --- Data ------------------------------------------------------------------
boot_info_ptr:  dd 0
boot_drive:     db 0
ipc_pid:        dd 0
idle_counter:   dd 0
last_ipc_tick:  dd 0
last_render_tick: dd 0

msg_banner:     db "X86ASMOS 32-bit kernel (protected mode)", 0x0A, 0
msg_ready:      db "scheduler running", 0x0A, 0
msg_badinfo:    db "ERROR: bad boot info magic", 0

; -----------------------------------------------------------------------------
; Include the rest of the kernel modules.
; -----------------------------------------------------------------------------
%include "src/kernel/vga.asm"
%include "src/kernel/serial.asm"
%include "src/kernel/gdt.asm"
%include "src/kernel/pic.asm"
%include "src/kernel/idt.asm"
%include "src/kernel/pmm.asm"
%include "src/kernel/paging.asm"
%include "src/kernel/kmalloc.asm"
%include "src/kernel/syscall.asm"
%include "src/drivers/pit.asm"
%include "src/drivers/keyboard.asm"
%include "src/drivers/mouse.asm"
%include "src/drivers/ata.asm"
%include "src/fs/fat32.asm"
%include "src/sched/task.asm"
%include "src/gui/gfx.asm"
%include "src/gui/gui.asm"
%include "src/jit/jit.asm"
%include "src/audio/speaker.asm"
%include "src/audio/mixer.asm"
%include "src/net/pci.asm"
%include "src/net/rtl8139.asm"
%include "src/net/net.asm"
%include "src/user/demo.asm"
