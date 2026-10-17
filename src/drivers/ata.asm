; =============================================================================
; X86ASMOS - ATA/IDE PIO Driver (primary master)
; -----------------------------------------------------------------------------
; Reads and writes sectors using 28-bit LBA programmed I/O on the primary IDE
; channel (I/O ports 0x1F0-0x1F7). PIO is simple and works in QEMU; DMA would
; be a drop-in replacement for the same sector-level interface.
;
; Public interface:
;   ata_read_sectors  - EAX=LBA, ECX=count, EDI=buffer
;   ata_write_sectors - EAX=LBA, ECX=count, ESI=buffer
; =============================================================================

ATA_DATA    equ 0x1F0
ATA_ERROR   equ 0x1F1
ATA_COUNT   equ 0x1F2
ATA_LBA_LO  equ 0x1F3
ATA_LBA_MID equ 0x1F4
ATA_LBA_HI  equ 0x1F5
ATA_DRIVE   equ 0x1F6
ATA_STATUS  equ 0x1F7
ATA_CMD     equ 0x1F7

ATA_CMD_READ  equ 0x20
ATA_CMD_WRITE equ 0x30

ata_lba:    dd 0
ata_count:  dd 0
ata_buffer: dd 0

; -----------------------------------------------------------------------------
; ata_read_sectors - EAX=LBA, ECX=count, EDI=buffer.
; -----------------------------------------------------------------------------
ata_read_sectors:
    pusha
    mov [ata_lba], eax
    mov [ata_count], ecx
    mov [ata_buffer], edi

    ; Detect a floating bus (no drive present): status reads 0xFF.
    mov dx, ATA_STATUS
    in al, dx
    cmp al, 0xFF
    je .no_drive

    call ata_wait_not_busy

    mov eax, [ata_lba]
    mov dx, ATA_DRIVE
    shr eax, 24
    and al, 0x0F
    or al, 0xE0                         ; LBA mode, master drive
    out dx, al

    mov dx, ATA_COUNT
    mov eax, [ata_count]
    out dx, al

    mov dx, ATA_LBA_LO
    mov eax, [ata_lba]
    out dx, al
    mov dx, ATA_LBA_MID
    mov eax, [ata_lba]
    shr eax, 8
    out dx, al
    mov dx, ATA_LBA_HI
    mov eax, [ata_lba]
    shr eax, 16
    out dx, al

    mov dx, ATA_CMD
    mov al, ATA_CMD_READ
    out dx, al

    call ata_wait_drq

    mov ecx, [ata_count]
    shl ecx, 8                          ; count * 256 words
    mov edi, [ata_buffer]
    mov dx, ATA_DATA
    rep insw

    call ata_wait_not_busy
    popa
    ret

.no_drive:
    popa
    ret

; -----------------------------------------------------------------------------
; ata_write_sectors - EAX=LBA, ECX=count, ESI=buffer.
; -----------------------------------------------------------------------------
ata_write_sectors:
    pusha
    mov [ata_lba], eax
    mov [ata_count], ecx
    mov [ata_buffer], esi

    mov dx, ATA_STATUS
    in al, dx
    cmp al, 0xFF
    je .no_drive

    call ata_wait_not_busy

    mov eax, [ata_lba]
    mov dx, ATA_DRIVE
    shr eax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al

    mov dx, ATA_COUNT
    mov eax, [ata_count]
    out dx, al

    mov dx, ATA_LBA_LO
    mov eax, [ata_lba]
    out dx, al
    mov dx, ATA_LBA_MID
    mov eax, [ata_lba]
    shr eax, 8
    out dx, al
    mov dx, ATA_LBA_HI
    mov eax, [ata_lba]
    shr eax, 16
    out dx, al

    mov dx, ATA_CMD
    mov al, ATA_CMD_WRITE
    out dx, al

    call ata_wait_drq

    mov ecx, [ata_count]
    shl ecx, 8
    mov esi, [ata_buffer]
    mov dx, ATA_DATA
    rep outsw

    call ata_wait_not_busy
    popa
    ret

.no_drive:
    popa
    ret

; -----------------------------------------------------------------------------
; ata_wait_not_busy - wait for BSY (bit 7) to clear.
; -----------------------------------------------------------------------------
ata_wait_not_busy:
    push eax
    push ecx
    push edx
    mov ecx, 0xFFFF
.loop:
    mov dx, ATA_STATUS
    in al, dx
    test al, 0x80
    jz .done
    loop .loop
.done:
    pop edx
    pop ecx
    pop eax
    ret

; -----------------------------------------------------------------------------
; ata_wait_drq - wait for DRQ (bit 3) to set; bail on error (bit 0).
; -----------------------------------------------------------------------------
ata_wait_drq:
    push eax
    push ecx
    push edx
    mov ecx, 0xFFFF
.loop:
    mov dx, ATA_STATUS
    in al, dx
    test al, 0x08
    jnz .done
    test al, 0x01
    jnz .done
    loop .loop
.done:
    pop edx
    pop ecx
    pop eax
    ret
