; =============================================================================
; X86ASMOS - PCI Bus Access
; -----------------------------------------------------------------------------
; Reads/writes PCI configuration space via the classic 0xCF8/0xCFC mechanism
; and scans the bus for a device by vendor/device ID.
;
; Public interface:
;   pci_config_read   - EAX=(bus<<16|dev<<11|func<<8|offset), returns EAX=value
;   pci_config_write  - same encoding, EBX=value
;   pci_find_device   - EAX=vendor|device<<16 -> EAX=device loc (0 if none)
; =============================================================================

PCI_ADDR_PORT equ 0xCF8
PCI_DATA_PORT equ 0xCFC

; -----------------------------------------------------------------------------
; pci_config_read - EAX = (bus<<16 | dev<<11 | func<<8 | offset).
; Returns EAX = 32-bit value.
; -----------------------------------------------------------------------------
pci_config_read:
    push edx
    mov edx, PCI_ADDR_PORT
    or eax, 0x80000000
    out dx, eax
    mov edx, PCI_DATA_PORT
    in eax, dx
    pop edx
    ret

; -----------------------------------------------------------------------------
; pci_config_write - EAX = address, EBX = value.
; -----------------------------------------------------------------------------
pci_config_write:
    push edx
    push eax
    mov edx, PCI_ADDR_PORT
    or eax, 0x80000000
    out dx, eax
    mov edx, PCI_DATA_PORT
    mov eax, ebx
    out dx, eax
    pop eax
    pop edx
    ret

; -----------------------------------------------------------------------------
; pci_find_device - EAX = vendor | (device << 16).
; Returns EAX = (bus<<16 | dev<<11 | func<<8) or 0 if not found.
; -----------------------------------------------------------------------------
pci_find_device:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov esi, eax                        ; target vendor/device
    xor ebx, ebx                        ; bus
.bus_loop:
    xor ecx, ecx                        ; device
.dev_loop:
    xor edx, edx                        ; function
.func_loop:
    mov eax, ebx
    shl eax, 16
    mov edi, ecx
    shl edi, 11
    or eax, edi
    mov edi, edx
    shl edi, 8
    or eax, edi                         ; address = bus/dev/func, offset 0
    call pci_config_read
    cmp eax, esi                        ; vendor/device match?
    je .found
    ; function 0 has bit 7 of header type clear = not multifunction
    test edx, edx
    jnz .next_dev
    ; check header type bit 7 for multifunction
    mov eax, ebx
    shl eax, 16
    mov edi, ecx
    shl edi, 11
    or eax, edi
    add eax, 0x0C                       ; header type offset
    call pci_config_read
    shr eax, 16
    and eax, 0x80                       ; multifunction bit
    jz .next_dev
    inc edx
    cmp edx, 8
    jb .func_loop
.next_dev:
    inc ecx
    cmp ecx, 32
    jb .dev_loop
    inc ebx
    cmp ebx, 256
    jb .bus_loop
    xor eax, eax                        ; not found
    jmp .done
.found:
    mov eax, ebx
    shl eax, 16
    mov edi, ecx
    shl edi, 11
    or eax, edi
    mov edi, edx
    shl edi, 8
    or eax, edi
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
