; =============================================================================
; X86ASMOS - RTL8139 Fast Ethernet Driver
; -----------------------------------------------------------------------------
; Finds the RTL8139 via PCI, initialises it, and provides polled send/receive.
; Uses fixed physically-contiguous DMA buffers below 4 MiB (identity mapped).
;
; Public interface:
;   rtl8139_init    - returns EAX=0 on success (NIC present and ready)
;   rtl8139_send    - ESI=frame, ECX=length
;   rtl8139_receive - EDI=buffer -> EAX=length (0 if none)
;   rtl8139_mac     - 6-byte MAC address
; =============================================================================

RTL8139_VENDOR equ 0x10EC
RTL8139_DEVICE equ 0x8139

; Register offsets (from I/O base)
RT_IDR       equ 0x00
RT_TSD0      equ 0x10
RT_TSAD0     equ 0x20
RT_RBSTART   equ 0x30
RT_CR        equ 0x37
RT_CAPR      equ 0x38
RT_CBR       equ 0x3A
RT_IMR       equ 0x3C
RT_ISR       equ 0x3E
RT_TCR       equ 0x40
RT_RCR       equ 0x44
RT_CONFIG1   equ 0x52

; Fixed DMA buffers (below 4 MiB, reserved, identity-mapped).
RT_RX_BUFFER   equ 0x300000        ; 8 KiB receive ring
RT_TX_BUFFER   equ 0x308000        ; 4 x 2048 transmit buffers
RT_RX_SIZE     equ 8192

rtl8139_io:      dd 0
rtl8139_tx_cur:  dd 0
rtl_rx_offset:   dd 0
rtl8139_mac:     db 0, 0, 0, 0, 0, 0

; -----------------------------------------------------------------------------
rtl8139_init:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; Find the device.
    mov eax, RTL8139_VENDOR | (RTL8139_DEVICE << 16)
    call pci_find_device
    test eax, eax
    jz .fail
    mov [pci_device_loc], eax

    ; Read BAR0 (offset 0x10) -> I/O base.
    or eax, 0x10
    call pci_config_read
    and eax, ~0x03
    mov [rtl8139_io], eax

    ; Enable bus mastering + I/O space in the PCI command register.
    mov eax, [pci_device_loc]
    or eax, 0x04
    call pci_config_read                  ; command register
    or eax, 0x05                          ; I/O space (bit 0) + bus master (bit 2)
    mov ebx, eax
    mov eax, [pci_device_loc]
    or eax, 0x04
    call pci_config_write

    ; Read the MAC address.
    mov esi, rtl8139_mac
    mov edx, [rtl8139_io]
    mov ecx, 6
.mac_loop:
    in al, dx
    mov [esi], al
    inc esi
    inc edx
    loop .mac_loop

    ; Power on.
    mov edx, [rtl8139_io]
    add edx, RT_CONFIG1
    mov al, 0x00
    out dx, al

    ; Software reset.
    mov edx, [rtl8139_io]
    add edx, RT_CR
    mov al, 0x10
    out dx, al
.reset_wait:
    in al, dx
    test al, 0x10
    jnz .reset_wait

    ; Set receive buffer start.
    mov edx, [rtl8139_io]
    add edx, RT_RBSTART
    mov eax, RT_RX_BUFFER
    out dx, eax

    ; Configure TCR and RCR.
    mov edx, [rtl8139_io]
    add edx, RT_TCR
    mov eax, 0x03000700
    out dx, eax
    mov edx, [rtl8139_io]
    add edx, RT_RCR
    mov eax, 0x0000000F                  ; accept phys/multicast/broadcast, 8K
    out dx, eax

    ; Clear interrupt mask/status (polled driver).
    mov edx, [rtl8139_io]
    add edx, RT_IMR
    xor eax, eax
    out dx, ax

    ; Enable receive + transmit.
    mov edx, [rtl8139_io]
    add edx, RT_CR
    mov al, 0x0C
    out dx, al

    mov dword [rtl8139_tx_cur], 0
    mov dword [rtl_rx_offset], 0

    xor eax, eax
    jmp .done
.fail:
    mov eax, 1
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

pci_device_loc: dd 0

; -----------------------------------------------------------------------------
; rtl8139_send - ESI = frame buffer, ECX = length. Uses round-robin TX
; descriptors (the RTL8139 ignores a descriptor pair once it has advanced
; past it).
; -----------------------------------------------------------------------------
rtl8139_send:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov [rtl_len], ecx
    mov [rtl_frame], esi

    mov eax, [rtl8139_tx_cur]            ; descriptor 0..3
    mov ebx, eax
    shl ebx, 2                           ; desc * 4

    ; Wait for this descriptor's OWN bit to be set (free).
    mov edx, [rtl8139_io]
    add edx, RT_TSD0
    add edx, ebx
.wait_free:
    in eax, dx
    test eax, 0x2000
    jz .wait_free

    ; Copy the frame to this descriptor's TX buffer.
    mov esi, [rtl_frame]
    mov edi, RT_TX_BUFFER
    mov eax, [rtl8139_tx_cur]
    shl eax, 11                          ; desc * 2048
    add edi, eax
    mov ecx, [rtl_len]
    rep movsb

    ; TSAD<desc> = buffer.
    mov eax, [rtl8139_tx_cur]
    shl eax, 11
    add eax, RT_TX_BUFFER
    mov edx, [rtl8139_io]
    add edx, RT_TSAD0
    add edx, ebx
    out dx, eax

    ; TSD<desc> = length (OWN=0 starts transmission).
    mov eax, [rtl_len]
    mov edx, [rtl8139_io]
    add edx, RT_TSD0
    add edx, ebx
    out dx, eax

    ; Advance to the next descriptor.
    mov eax, [rtl8139_tx_cur]
    inc eax
    and eax, 3
    mov [rtl8139_tx_cur], eax

    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

rtl_len:   dd 0
rtl_frame: dd 0

; -----------------------------------------------------------------------------
; rtl8139_receive - EDI = destination buffer. Returns EAX = length (0 if none).
; Uses a software read offset (rtl_rx_offset); CAPR is written with the -16
; quirk the RTL8139 requires.
; -----------------------------------------------------------------------------
rtl8139_receive:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov [net_dest], edi

    ; Check if the RX buffer is empty (BUFE bit).
    mov edx, [rtl8139_io]
    add edx, RT_CR
    in al, dx
    test al, 0x01
    jnz .none

    mov eax, [rtl_rx_offset]
    mov [net_capr], eax

    mov esi, RT_RX_BUFFER
    add esi, eax                        ; packet header
    movzx ebx, word [esi]               ; status
    movzx ecx, word [esi + 2]           ; length (data + 4-byte CRC)

    test ebx, 0x0001                    ; ROK bit
    jz .advance
    cmp ecx, 64
    jb .advance
    cmp ecx, 1518
    ja .advance

    ; Copy the payload (length - 4 bytes).
    mov [net_hdrlen], ecx
    sub ecx, 4
    add esi, 4
    mov edi, [net_dest]
    mov [net_pktlen], ecx
    rep movsb

    ; Advance the software read offset.
    mov eax, [rtl_rx_offset]
    add eax, 4
    add eax, [net_hdrlen]
    add eax, 3
    and eax, ~3
    cmp eax, RT_RX_SIZE
    jb .no_wrap
    sub eax, RT_RX_SIZE
.no_wrap:
    mov [rtl_rx_offset], eax
    sub eax, 16
    jns .write_capr
    add eax, RT_RX_SIZE
.write_capr:
    mov edx, [rtl8139_io]
    add edx, RT_CAPR
    out dx, ax

    mov eax, [net_pktlen]               ; return payload length
    jmp .done

.advance:
    mov eax, [rtl_rx_offset]
    add eax, 4
    add eax, ecx
    add eax, 3
    and eax, ~3
    cmp eax, RT_RX_SIZE
    jb .no_wrap2
    sub eax, RT_RX_SIZE
.no_wrap2:
    mov [rtl_rx_offset], eax
    sub eax, 16
    jns .write_capr2
    add eax, RT_RX_SIZE
.write_capr2:
    mov edx, [rtl8139_io]
    add edx, RT_CAPR
    out dx, ax

.none:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

net_dest:   dd 0
net_capr:   dd 0
net_hdrlen: dd 0
net_pktlen: dd 0
