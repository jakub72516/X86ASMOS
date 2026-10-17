; =============================================================================
; X86ASMOS - FAT32 Filesystem Driver
; -----------------------------------------------------------------------------
; Reads and writes a FAT32 filesystem located at a fixed partition LBA (2048)
; on the primary ATA disk. Supports root-directory listing, file lookup, file
; reading, and single-cluster file creation. The on-disk layout matches the
; tools/mkfat32.py formatter.
;
; Public interface:
;   fat32_init       - parse the BPB and compute geometry
;   fat32_list_dir   - print root directory entries to serial
;   fat32_find_file  - ESI=11-byte name -> EAX=cluster, EBX=size
;   fat32_read_file  - ESI=11-byte name, EDI=buffer -> EAX=size
;   fat32_write_file - ESI=11-byte name, EDI=data, ECX=size -> EAX=0 ok
; =============================================================================

FAT32_PARTITION_LBA equ 2048

fat32_spc:          dd 0
fat32_reserved:     dd 0
fat32_num_fats:     dd 0
fat32_fat_size:     dd 0
fat32_root_cluster: dd 0
fat32_total:        dd 0
fat32_fat_lba:      dd 0
fat32_data_lba:     dd 0
fat32_sector:       dd 0        ; 512-byte scratch buffer

fat32_file_cluster: dd 0
fat32_file_size:    dd 0

; -----------------------------------------------------------------------------
fat32_init:
    pusha

    mov eax, 512
    call kmalloc
    mov [fat32_sector], eax

    ; Read the BPB from the partition start.
    mov eax, FAT32_PARTITION_LBA
    mov ecx, 1
    mov edi, [fat32_sector]
    call ata_read_sectors

    mov esi, [fat32_sector]
    movzx eax, byte [esi + 13]
    mov [fat32_spc], eax
    movzx eax, word [esi + 14]
    mov [fat32_reserved], eax
    movzx eax, byte [esi + 16]
    mov [fat32_num_fats], eax
    mov eax, [esi + 36]
    mov [fat32_fat_size], eax
    mov eax, [esi + 44]
    mov [fat32_root_cluster], eax
    mov eax, [esi + 32]
    mov [fat32_total], eax

    mov eax, FAT32_PARTITION_LBA
    add eax, [fat32_reserved]
    mov [fat32_fat_lba], eax
    mov eax, [fat32_fat_size]
    imul eax, [fat32_num_fats]
    add eax, [fat32_fat_lba]
    mov [fat32_data_lba], eax

    popa
    ret

; -----------------------------------------------------------------------------
; fat32_cluster_to_lba - EAX = cluster -> EAX = LBA of its first sector.
; -----------------------------------------------------------------------------
fat32_cluster_to_lba:
    push ecx
    push edx
    sub eax, 2
    mov ecx, [fat32_spc]
    imul eax, ecx
    add eax, [fat32_data_lba]
    pop edx
    pop ecx
    ret

; -----------------------------------------------------------------------------
; fat32_next_cluster - EAX = cluster -> EAX = next cluster (EOC on end).
; -----------------------------------------------------------------------------
fat32_next_cluster:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov ebx, eax
    shl eax, 2                          ; cluster * 4 (FAT byte offset)
    mov ecx, eax
    shr ecx, 9                          ; FAT sector index
    and eax, 511                        ; entry offset within sector

    push eax
    mov eax, [fat32_fat_lba]
    add eax, ecx
    mov ecx, 1
    mov edi, [fat32_sector]
    call ata_read_sectors
    pop eax

    mov esi, [fat32_sector]
    add esi, eax
    mov eax, [esi]
    and eax, 0x0FFFFFFF

    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; fat32_list_dir - print root directory entry names to serial.
; -----------------------------------------------------------------------------
fat32_list_dir:
    pusha

    mov eax, [fat32_root_cluster]
    call fat32_cluster_to_lba
    mov ecx, [fat32_spc]
    mov edi, [fat32_sector]
    call ata_read_sectors

    mov esi, [fat32_sector]
    mov ecx, [fat32_spc]
    shl ecx, 4                          ; entries = spc * 16

.entry:
    cmp byte [esi], 0
    je .done
    cmp byte [esi], 0xE5
    je .next
    cmp byte [esi + 11], 0x0F           ; LFN entry
    je .next

    call fat32_print_entry              ; prints "  name  size\n"
.next:
    add esi, 32
    loop .entry
.done:
    popa
    ret

; -----------------------------------------------------------------------------
; fat32_print_entry - ESI = directory entry. Prints "  <name> size=<size>".
; -----------------------------------------------------------------------------
fat32_print_entry:
    pusha
    mov [fat32_entry_ptr], esi

    mov esi, msg_fs_indent
    call serial_write

    ; base name (8 chars)
    mov ebp, [fat32_entry_ptr]
    mov ecx, 8
.base:
    mov al, [ebp]
    cmp al, ' '
    je .b_skip
    call serial_putchar
.b_skip:
    inc ebp
    loop .base

    ; extension (if present)
    mov al, [ebp]
    cmp al, ' '
    je .no_ext
    mov al, '.'
    call serial_putchar
    mov ecx, 3
.ext:
    mov al, [ebp]
    cmp al, ' '
    je .e_skip
    call serial_putchar
.e_skip:
    inc ebp
    loop .ext
.no_ext:

    mov esi, msg_fs_size
    call serial_write
    mov ebp, [fat32_entry_ptr]
    mov eax, [ebp + 28]
    call serial_write_hex
    call serial_newline
    popa
    ret

; -----------------------------------------------------------------------------
; fat32_find_file - ESI = 11-byte name (space-padded, uppercase).
; Returns EAX = first cluster (0 = not found), EBX = size.
; -----------------------------------------------------------------------------
fat32_find_file:
    push ecx
    push edx
    push esi
    push edi
    push ebp

    mov ebp, esi                        ; target name

    mov eax, [fat32_root_cluster]
    call fat32_cluster_to_lba
    mov ecx, [fat32_spc]
    mov edi, [fat32_sector]
    call ata_read_sectors

    mov esi, [fat32_sector]
    mov ecx, [fat32_spc]
    shl ecx, 4

.entry:
    cmp byte [esi], 0
    je .not_found
    cmp byte [esi], 0xE5
    je .next
    cmp byte [esi + 11], 0x0F
    je .next

    push ecx
    push esi
    push edi
    mov ecx, 11
    mov edi, ebp
    repe cmpsb
    pop edi
    pop esi
    pop ecx
    jne .next

    ; match
    movzx eax, word [esi + 26]
    movzx ebx, word [esi + 20]
    shl ebx, 16
    or eax, ebx
    mov ebx, [esi + 28]
    jmp .done

.next:
    add esi, 32
    loop .entry

.not_found:
    xor eax, eax
    xor ebx, ebx
.done:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    ret

; -----------------------------------------------------------------------------
; fat32_read_file - ESI = 11-byte name, EDI = buffer. Returns EAX = size.
; -----------------------------------------------------------------------------
fat32_read_file:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    call fat32_find_file
    test eax, eax
    jz .not_found
    mov [fat32_file_cluster], eax
    mov [fat32_file_size], ebx

.read_loop:
    mov eax, [fat32_file_cluster]
    cmp eax, 0x0FFFFFF7
    jae .finished
    call fat32_cluster_to_lba
    mov ecx, [fat32_spc]
    call ata_read_sectors                ; EDI = destination
    mov eax, [fat32_spc]
    shl eax, 9
    add edi, eax
    mov eax, [fat32_file_cluster]
    call fat32_next_cluster
    mov [fat32_file_cluster], eax
    jmp .read_loop

.finished:
    mov eax, [fat32_file_size]
    jmp .done
.not_found:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; fat32_write_file - ESI = 11-byte name, EDI = data (full cluster), ECX = size.
; Returns EAX = 0 on success, 1 on failure.
; -----------------------------------------------------------------------------
fat32_write_file:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp

    mov ebp, esi                        ; name
    mov [fat32_file_size], ecx          ; size

    ; Find a free cluster.
    call fat32_find_free_cluster
    test eax, eax
    jz .fail
    mov [fat32_file_cluster], eax

    ; Write data (the buffer must be a full cluster: spc sectors).
    call fat32_cluster_to_lba
    mov ecx, [fat32_spc]
    mov esi, edi                        ; source = data buffer
    call ata_write_sectors

    ; Mark FAT entry as EOC.
    mov eax, [fat32_file_cluster]
    mov ebx, 0x0FFFFFFF
    call fat32_set_fat_entry

    ; Write the directory entry.
    mov esi, ebp
    call fat32_write_dir_entry
    test eax, eax
    jnz .fail

    xor eax, eax                        ; success
    jmp .done
.fail:
    mov eax, 1
.done:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; fat32_find_free_cluster - returns EAX = first free cluster (0 if none).
; -----------------------------------------------------------------------------
fat32_find_free_cluster:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    xor ebx, ebx                        ; cluster number being checked

.scan:
    inc ebx                             ; start at cluster 1
    ; read the FAT sector containing cluster ebx
    mov eax, ebx
    shl eax, 2                          ; byte offset
    mov ecx, eax
    shr ecx, 9                          ; sector index
    and eax, 511                        ; offset
    push eax
    push ebx
    mov eax, [fat32_fat_lba]
    add eax, ecx
    mov ecx, 1
    mov edi, [fat32_sector]
    call ata_read_sectors
    pop ebx
    pop eax
    mov esi, [fat32_sector]
    add esi, eax
    mov edx, [esi]
    and edx, 0x0FFFFFFF
    test edx, edx                       ; free?
    jz .found
    cmp ebx, [fat32_total]              ; scanned everything?
    jb .scan
    xor eax, eax
    jmp .done
.found:
    mov eax, ebx
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; fat32_set_fat_entry - EAX = cluster, EBX = value. Writes both FAT copies.
; -----------------------------------------------------------------------------
fat32_set_fat_entry:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov esi, eax
    shl esi, 2                          ; byte offset = cluster * 4
    mov ecx, esi
    shr ecx, 9                          ; FAT sector index
    and esi, 511                        ; entry offset within sector
    mov [fat32_entry_sector], ecx
    mov [fat32_entry_offset], esi

    ; Read the FAT sector and patch the entry.
    mov eax, [fat32_fat_lba]
    add eax, ecx
    mov ecx, 1
    mov edi, [fat32_sector]
    call ata_read_sectors
    mov esi, [fat32_sector]
    add esi, [fat32_entry_offset]
    mov [esi], ebx

    ; Write back to the first FAT.
    mov eax, [fat32_fat_lba]
    add eax, [fat32_entry_sector]
    mov ecx, 1
    mov esi, [fat32_sector]
    call ata_write_sectors

    ; Write back to the second FAT copy.
    mov eax, [fat32_fat_lba]
    add eax, [fat32_fat_size]
    add eax, [fat32_entry_sector]
    mov ecx, 1
    mov esi, [fat32_sector]
    call ata_write_sectors

    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; -----------------------------------------------------------------------------
; fat32_write_dir_entry - ESI = 11-byte name. Uses fat32_file_cluster/size.
; Returns EAX = 0 ok, 1 fail (via the saved EAX slot).
; -----------------------------------------------------------------------------
fat32_write_dir_entry:
    pusha
    mov [fat32_entry_ptr], esi          ; name pointer

    mov eax, [fat32_root_cluster]
    call fat32_cluster_to_lba
    mov ecx, [fat32_spc]
    mov edi, [fat32_sector]
    call ata_read_sectors

    ; Find a free slot.
    mov edi, [fat32_sector]
    mov ecx, [fat32_spc]
    shl ecx, 4
.find:
    cmp byte [edi], 0
    je .slot
    cmp byte [edi], 0xE5
    je .slot
    add edi, 32
    loop .find
    mov dword [esp + 28], 1             ; directory full
    jmp .done

.slot:
    ; Copy the 11-byte name.
    mov esi, [fat32_entry_ptr]
    push ecx
    mov ecx, 11
    rep movsb
    pop ecx

    sub edi, 11
    mov byte [edi + 11], 0x20           ; archive attribute
    mov eax, [fat32_file_cluster]
    mov word [edi + 26], ax             ; cluster low
    shr eax, 16
    mov word [edi + 20], ax             ; cluster high
    mov eax, [fat32_file_size]
    mov [edi + 28], eax                 ; size

    ; Write the directory cluster back.
    mov eax, [fat32_root_cluster]
    call fat32_cluster_to_lba
    mov ecx, [fat32_spc]
    mov esi, [fat32_sector]
    call ata_write_sectors

    mov dword [esp + 28], 0             ; success
.done:
    popa
    ret

msg_fs_indent: db "  ", 0
msg_fs_size:   db " size=", 0

fat32_entry_ptr:    dd 0
fat32_entry_sector: dd 0
fat32_entry_offset: dd 0
