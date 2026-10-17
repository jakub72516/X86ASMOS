; =============================================================================
; X86ASMOS - Stage 2 Loader
; -----------------------------------------------------------------------------
; Loaded by the Stage 1 boot sector to 0x8000 and entered in 16-bit real mode
; with DL = boot drive number. It:
;
;   1. Prints a banner.
;   2. Enables the A20 line (unlocks memory above 1 MiB).
;   3. Loads the kernel into a low-memory staging buffer (0x10000) using
;      BIOS LBA extensions if present, falling back to CHS. A BIOS disk read
;      cannot directly address above 1 MiB (its buffer pointer is 16:16), so
;      the kernel is staged low and copied up after entering protected mode.
;   4. Queries the BIOS memory map (int 15h E820) into a boot info block.
;   5. Builds a flat GDT and switches into 32-bit protected mode.
;   6. Copies the kernel from 0x10000 to 0x100000 and jumps to it.
;
; Boot information block (passed to kernel in ESI, linear address 0x5000):
;   +0x00  magic        dd 0x41534F53 ("SOSA")
;   +0x04  mmap_count   dd number of valid E820 entries
;   +0x08  mmap         E820 entries, 24 bytes each (max 64)
;   +0x608 boot_drive   db BIOS drive number
;
; The staging buffer limits the kernel image to 512 KiB (0x10000..0x90000).
; =============================================================================

BITS 16
ORG 0x8000

KERNEL_LOAD     equ 0x100000        ; 1 MiB - final kernel address
STAGING_SEG     equ 0x1000          ; low-memory staging area (0x10000)
BOOT_INFO       equ 0x5000          ; boot information block address

; Video info (filled by set_video_mode; 0 = text mode fallback)
BOOT_VIDEO      equ 0x5610
VIDEO_WIDTH     equ BOOT_VIDEO + 0
VIDEO_HEIGHT    equ BOOT_VIDEO + 2
VIDEO_BPP       equ BOOT_VIDEO + 4
VIDEO_PITCH     equ BOOT_VIDEO + 5
VIDEO_FB        equ BOOT_VIDEO + 7

VBE_INFO_BLOCK  equ 0x2000          ; VBE controller info buffer (512 bytes)
VBE_MODE_BLOCK  equ 0x2400          ; VBE mode info buffer (256 bytes)

GDT_CODE0       equ 0x08
GDT_DATA0       equ 0x10
GDT_CODE3       equ 0x18            ; ring 3 code (RPL 3 = 0x1B)
GDT_DATA3       equ 0x20            ; ring 3 data (RPL 3 = 0x23)

; KERNEL_SECTORS is supplied by the build script (-DKERNEL_SECTORS=<n>),
; computed from the actual size of the assembled kernel.
%ifndef KERNEL_SECTORS
%define KERNEL_SECTORS 256
%endif

stage2_start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, 0x8000                  ; stack just below us (grows down)

    mov [BOOT_DRIVE], dl            ; save boot drive
    mov [BOOT_INFO + 0x608], dl
    mov dword [BOOT_INFO], 0x41534F53  ; boot info magic ("SOSA")

    mov si, msg_banner
    call print_string

    ; ------------------------------------------------------------------
    ; Enable A20. First ask the BIOS, then force it via the fast A20 port.
    ; ------------------------------------------------------------------
    mov ax, 0x2401
    int 0x15

    in al, 0x92
    or al, 0x02
    out 0x92, al

    ; ------------------------------------------------------------------
    ; Load the kernel into the low staging buffer.
    ; ------------------------------------------------------------------
    mov si, msg_loading
    call print_string

    call detect_lba
    test ax, ax
    jz .use_chs
    call load_kernel_lba
    jmp .loaded
.use_chs:
    call load_kernel_chs
.loaded:
    mov si, msg_ok
    call print_string

    ; ------------------------------------------------------------------
    ; Query the BIOS memory map (E820) into the boot info block.
    ; ------------------------------------------------------------------
    call detect_memory

    ; ------------------------------------------------------------------
    ; Select a graphics mode via VBE (before leaving real mode).
    ; ------------------------------------------------------------------
    call set_video_mode

    ; ------------------------------------------------------------------
    ; Enter protected mode.
    ; ------------------------------------------------------------------
    cli
    lgdt [gdt_ptr]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp GDT_CODE0:pmode_start

; =============================================================================
; detect_lba - test BIOS extensions (int 13h AH=41h).
; Returns AX = 1 if LBA extensions supported, 0 otherwise.
; =============================================================================
detect_lba:
    push bx
    push cx
    push dx
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [BOOT_DRIVE]
    int 0x13
    jc .not_supported
    cmp bx, 0xAA55
    jne .not_supported
    test cl, 0x01
    jz .not_supported
    mov ax, 1
    jmp .done
.not_supported:
    xor ax, ax
.done:
    pop dx
    pop cx
    pop bx
    ret

; =============================================================================
; load_kernel_lba - read KERNEL_SECTORS sectors (LBA KERNEL_LBA_START) into
; the staging buffer using int 13h AH=42h, 64 sectors per call to stay within
; a 64 KiB segment window.
; =============================================================================
load_kernel_lba:
    pusha
    mov dword [dap_lba], KERNEL_LBA_START
    mov word  [dap_seg], STAGING_SEG
    mov word  [dap_off], 0
    mov cx, KERNEL_SECTORS

.read:
    mov ax, cx
    cmp ax, 64
    jbe .do_read
    mov ax, 64
.do_read:
    mov word [dap_count], ax
    mov ah, 0x42
    mov dl, [BOOT_DRIVE]
    mov si, dap
    push cx
    int 0x13
    pop cx
    jc load_error

    sub cx, ax                      ; sectors remaining
    jz .done

    add word [dap_lba], ax
    adc word [dap_lba + 2], 0
    ; advance buffer by 64 sectors * 512 = 0x8000 bytes
    add word [dap_off], 0x8000
    jnc .read
    add word [dap_seg], 0x1000      ; crossed a 64 KiB boundary
    jmp .read
.done:
    popa
    ret

; =============================================================================
; load_kernel_chs - legacy CHS read into the staging buffer, one sector at a
; time with LBA->CHS conversion so it works on any geometry.
; =============================================================================
load_kernel_chs:
    pusha
    call get_geometry

    mov word [curr_lba], KERNEL_LBA_START
    mov ax, STAGING_SEG
    mov es, ax
    mov bx, 0x0000
    mov cx, KERNEL_SECTORS

.read_one:
    push cx
    mov ax, [curr_lba]
    xor dx, dx
    div word [spt]                  ; AX = temp, DX = (sector-1)
    inc dx                          ; DX = 1-based sector number
    mov cl, dl
    xor dx, dx
    div word [heads]                ; AX = cylinder, DX = head
    mov dh, dl                      ; head number
    mov ch, al                      ; cylinder low 8 bits
    mov al, 1
    mov ah, 0x02
    mov dl, [BOOT_DRIVE]
    int 0x13
    jc load_error

    inc word [curr_lba]
    add bx, 512
    pop cx
    loop .read_one

    popa
    ret

; -----------------------------------------------------------------------------
; get_geometry - query CHS geometry via int 13h AH=08h. Falls back to a
; sensible 16-head / 63-sector geometry if the BIOS call fails.
; -----------------------------------------------------------------------------
get_geometry:
    push ax
    push bx
    push cx
    push dx
    mov ah, 0x08
    mov dl, [BOOT_DRIVE]
    int 0x13
    jc .default
    movzx ax, dh
    inc ax
    mov [heads], ax
    mov al, cl
    and al, 0x3F
    movzx ax, al
    mov [spt], ax
    jmp .done
.default:
    mov word [heads], 16
    mov word [spt], 63
.done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =============================================================================
; detect_memory - read E820 map into BOOT_INFO. Sets BOOT_INFO+4 = count.
; =============================================================================
detect_memory:
    pusha
    xor ebx, ebx
    mov edi, BOOT_INFO + 0x08
    xor ebp, ebp
.next:
    mov eax, 0xE820
    mov ecx, 24
    mov edx, 0x534D4150             ; "SMAP"
    int 0x15
    jc .done
    cmp eax, 0x534D4150
    jne .done
    inc ebp
    add edi, 24
    test ebx, ebx
    jz .done
    cmp ebp, 64
    jb .next
.done:
    mov dword [BOOT_INFO + 0x04], ebp
    popa
    ret

; =============================================================================
; set_video_mode - use VESA BIOS Extensions to select 800x600x32bpp with a
; linear framebuffer, and record the result in the boot info block. Falls
; back to VGA text mode (video_width = 0) if VBE is unavailable.
; =============================================================================
set_video_mode:
    pusha
    push es
    push fs

    ; Default: text mode fallback.
    mov word [VIDEO_WIDTH], 0
    mov word [VIDEO_HEIGHT], 0

    xor ax, ax
    mov es, ax

    ; Get VBE controller info.
    mov ax, 0x4F00
    mov di, VBE_INFO_BLOCK
    int 0x10
    cmp ax, 0x004F
    jne .done
    cmp dword [VBE_INFO_BLOCK], 'VESA'
    jne .done

    ; Save the video mode list pointer.
    mov ax, [VBE_INFO_BLOCK + 0x0E]
    mov [mode_list_off], ax
    mov ax, [VBE_INFO_BLOCK + 0x10]
    mov [mode_list_seg], ax

.mode_loop:
    mov fs, [mode_list_seg]
    mov si, [mode_list_off]
    mov cx, [fs:si]                     ; mode number
    cmp cx, 0xFFFF                      ; end of list
    je .done
    add si, 2
    mov [mode_list_off], si
    mov [found_mode], cx                ; int 0x10 may clobber CX

    ; Get mode info.
    mov ax, 0x4F01
    mov di, VBE_MODE_BLOCK
    int 0x10
    cmp ax, 0x004F
    jne .mode_loop

    ; Must be supported, 800x600x32.
    mov ax, [VBE_MODE_BLOCK + 0x00]
    test ax, 0x0001
    jz .mode_loop
    cmp word [VBE_MODE_BLOCK + 0x12], 800
    jne .mode_loop
    cmp word [VBE_MODE_BLOCK + 0x14], 600
    jne .mode_loop
    cmp byte [VBE_MODE_BLOCK + 0x19], 32
    jne .mode_loop

    ; Set the mode with the linear framebuffer bit.
    mov bx, [found_mode]
    or bx, 0x4000
    mov ax, 0x4F02
    int 0x10
    cmp ax, 0x004F
    jne .done

    ; Record the mode parameters.
    mov ax, [VBE_MODE_BLOCK + 0x12]
    mov [VIDEO_WIDTH], ax
    mov ax, [VBE_MODE_BLOCK + 0x14]
    mov [VIDEO_HEIGHT], ax
    mov al, [VBE_MODE_BLOCK + 0x19]
    mov [VIDEO_BPP], al
    mov ax, [VBE_MODE_BLOCK + 0x10]     ; bytes per scanline
    mov [VIDEO_PITCH], ax
    mov eax, [VBE_MODE_BLOCK + 0x28]    ; physical framebuffer address
    mov [VIDEO_FB], eax

.done:
    pop fs
    pop es
    popa
    ret

load_error:
    mov si, msg_load_error
    call print_string
    cli
    hlt
    jmp short $ - 2

; -----------------------------------------------------------------------------
; print_string - BIOS teletype print of a NUL-terminated string at DS:SI.
; -----------------------------------------------------------------------------
print_string:
    push ax
    push bx
.loop:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    mov bh, 0x00
    int 0x10
    jmp .loop
.done:
    pop bx
    pop ax
    ret

; =============================================================================
; 32-bit protected mode entry.
; =============================================================================
BITS 32
pmode_start:
    mov ax, GDT_DATA0
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000               ; temporary protected-mode stack

    ; Copy the kernel from the staging buffer up to its final address.
    mov esi, STAGING_SEG << 4      ; 0x10000
    mov edi, KERNEL_LOAD           ; 0x100000
    mov ecx, KERNEL_SECTORS * 128  ; sectors * 128 dwords
    rep movsd

    ; Pass boot info pointer in ESI, boot drive in DL to the kernel.
    mov esi, BOOT_INFO
    mov dl, [BOOT_DRIVE]

    jmp GDT_CODE0:KERNEL_LOAD

; =============================================================================
; Data
; =============================================================================
msg_banner:     db "X86ASMOS stage2 loader", 0x0D, 0x0A, 0
msg_loading:    db "loading kernel...", 0
msg_ok:         db "ok", 0x0D, 0x0A, 0
msg_load_error: db 0x0D, 0x0A, "X86ASMOS: kernel load failed", 0x0D, 0x0A, 0

BOOT_DRIVE:       db 0
curr_lba:         dw 0
spt:              dw 0
heads:            dw 0
mode_list_off:    dw 0
mode_list_seg:    dw 0
found_mode:       dw 0

; The kernel image begins at LBA = 1 (boot) + 16 (stage 2) = 17.
KERNEL_LBA_START equ 17

; Disk Address Packet for extended reads.
align 4
dap:
    .size   db 0x10
    .zero   db 0
    .count  dw 1
    .off    dw 0
    .seg    dw 0
    .lba    dd 0
    .lba_hi dd 0
dap_count equ dap + 2
dap_off   equ dap + 4
dap_seg   equ dap + 6
dap_lba   equ dap + 8

; =============================================================================
; Global Descriptor Table - flat 4 GiB model, ring 0 and ring 3.
; =============================================================================
align 8
gdt:
    dq 0                            ; null descriptor
    dw 0xFFFF, 0x0000, 0x9A00, 0x00CF ; 0x08 ring 0 code
    dw 0xFFFF, 0x0000, 0x9200, 0x00CF ; 0x10 ring 0 data
    dw 0xFFFF, 0x0000, 0xFA00, 0x00CF ; 0x18 ring 3 code
    dw 0xFFFF, 0x0000, 0xF200, 0x00CF ; 0x20 ring 3 data
gdt_end:

gdt_ptr:
    dw gdt_end - gdt - 1
    dd gdt

; =============================================================================
; Pad Stage 2 out to its reserved size (16 sectors = 8192 bytes).
; =============================================================================
times 8192 - ($ - $$) db 0
