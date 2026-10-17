; =============================================================================
; X86ASMOS - Stage 1 Boot Sector
; -----------------------------------------------------------------------------
; Runs in 16-bit real mode. The BIOS loads this 512-byte sector to 0x7C00
; and jumps to it with DL = boot drive number.
;
; Responsibilities:
;   1. Set up a clean, known-good state (segments, stack).
;   2. Reset the disk system.
;   3. Load the Stage 2 loader (src/boot/stage2.asm) from disk to 0x8000:0x0000.
;   4. Hand control over to Stage 2 with DL = boot drive.
;
; The image layout is described in docs/memory-map.txt.
; =============================================================================

BITS 16
ORG 0x7C00

STAGE2_SEG      equ 0x0800        ; Stage 2 is loaded at 0x0800:0x0000 (0x8000)
STAGE2_SECTORS  equ 16            ; Stage 2 may occupy up to 16 sectors (8 KiB)

start:
    cli                             ; Disable interrupts while we set segments
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00                  ; Stack grows down from just below us
    sti

    ; Preserve the boot drive number provided by the BIOS in DL.
    mov [BOOT_DRIVE], dl

    ; ------------------------------------------------------------------
    ; Reset the disk controller (BIOS int 13h, AH=00h) and retry a few
    ; times because floppy controllers are notoriously slow to spin up.
    ; ------------------------------------------------------------------
    mov ah, 0x00
    int 0x13
    jc disk_error

    ; ------------------------------------------------------------------
    ; Load Stage 2. We use CHS addressing (int 13h AH=02h) so this boot
    ; sector works on legacy floppy geometry and on floppy images booted
    ; with QEMU -fda. Stage 2 starts at LBA 1 (the sector right after us).
    ; ------------------------------------------------------------------
    mov bx, STAGE2_SEG
    mov es, bx                      ; ES:BX = destination buffer
    mov bx, 0x0000

    mov ah, 0x02                    ; BIOS: read sectors
    mov al, STAGE2_SECTORS          ; number of sectors to read
    mov ch, 0x00                    ; cylinder 0
    mov cl, 0x02                    ; sector 2 (1-based; sector 1 is us)
    mov dh, 0x00                    ; head 0
    mov dl, [BOOT_DRIVE]            ; boot drive
    int 0x13
    jc disk_error

    cmp al, STAGE2_SECTORS          ; did the BIOS read everything?
    jne disk_error

    ; ------------------------------------------------------------------
    ; Jump to Stage 2. DL still holds the boot drive number.
    ; ------------------------------------------------------------------
    jmp 0x0000:STAGE2_SEG << 4      ; far jump to 0x8000

disk_error:
    mov si, msg_disk_error
    call print_string
    cli
    hlt
    jmp short $ - 2

; -----------------------------------------------------------------------------
; print_string - print a NUL-terminated string in DS:SI using BIOS teletype.
; -----------------------------------------------------------------------------
print_string:
    push ax
    push bx
.loop:
    lodsb                           ; AL = [SI], SI++
    test al, al
    jz .done
    mov ah, 0x0E                    ; teletype output
    mov bh, 0x00
    int 0x10
    jmp .loop
.done:
    pop bx
    pop ax
    ret

msg_disk_error: db "X86ASMOS: disk read error", 0x0D, 0x0A, 0

BOOT_DRIVE:     db 0

; -----------------------------------------------------------------------------
; Pad to 510 bytes and write the boot signature.
; -----------------------------------------------------------------------------
times 510 - ($ - $$) db 0
dw 0xAA55
