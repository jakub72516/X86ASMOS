; =============================================================================
; X86ASMOS - Networking Stack (Ethernet / ARP / IPv4 / ICMP / UDP / DHCP / TCP)
; -----------------------------------------------------------------------------
; Compact TCP/IP stack for the RTL8139: DHCP an address, answer ARP + ping,
; and serve a static page over HTTP (minimal TCP). Packets are assembled in a
; fixed scratch buffer below 4 MiB.
;
; Buffers: NET_PKT 0x310000 (assembly), NET_RECV 0x311000 (receive).
; Public interface: net_init, net_task.
; =============================================================================

NET_PKT  equ 0x310000
NET_RECV equ 0x311000

ETHER_ARP  equ 0x0806
ETHER_IPV4 equ 0x0800

IPPROTO_ICMP equ 1
IPPROTO_TCP  equ 6
IPPROTO_UDP  equ 17

DHCP_CLIENT_PORT equ 68
DHCP_SERVER_PORT equ 67

our_ip:     db 0, 0, 0, 0
gateway_ip: db 0, 0, 0, 0
dns_ip:     db 0, 0, 0, 0
our_mac:    db 0, 0, 0, 0, 0, 0
dhcp_xid:   dd 0x58414D4F
dhcp_state: dd 0

; TCP state
tcp_our_seq:    dd 0x1000
tcp_client_seq: dd 0
tcp_client_ack: dd 0
tcp_client_port: dw 0

msg_net_start:  db "Net: RTL8139 init", 0x0A, 0
msg_mac:        db "MAC ", 0
msg_dhcp_start: db "DHCP discover", 0x0A, 0
msg_dhcp_ok:    db "DHCP: ", 0
msg_dhcp_done:  db " ready", 0x0A, 0
msg_http:       db "HTTP served", 0x0A, 0

; -----------------------------------------------------------------------------
net_init:
    pusha
    call rtl8139_init
    mov esi, rtl8139_mac
    mov edi, our_mac
    mov ecx, 6
    rep movsb
    mov dword [dhcp_state], 0
    popa
    ret

; -----------------------------------------------------------------------------
net_task:
    mov esi, msg_net_start
    call serial_write
    call net_init

    mov esi, msg_mac
    call serial_write
    mov ecx, 6
    xor ebx, ebx
.macp:
    movzx eax, byte [our_mac + ebx]
    call serial_write_hex
    inc ebx
    loop .macp
    call serial_newline

    mov esi, msg_dhcp_start
    call serial_write
    call dhcp_start

.loop:
    call net_poll
    mov eax, 2
    call task_sleep
    jmp .loop

; =============================================================================
; checksum - ESI=start, ECX=byte length -> AX
; =============================================================================
checksum:
    push ebx
    push ecx
    push edx
    push esi
    xor edx, edx
    mov ebx, ecx
    shr ebx, 1
.sum:
    test ebx, ebx
    jz .fold
    movzx eax, word [esi]
    add edx, eax
    add esi, 2
    dec ebx
    jmp .sum
.fold:
    mov eax, edx
    shr eax, 16
    and edx, 0xFFFF
    add eax, edx
    mov edx, eax
    shr edx, 16
    add eax, edx
    and eax, 0xFFFF
    not eax
    and eax, 0xFFFF
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; =============================================================================
; net_send - payload is at NET_PKT+14. ESI=dest MAC, EAX=ethertype, ECX=len.
; =============================================================================
net_send:
    push eax
    push ebx
    push ecx
    push esi
    push edi

    mov edi, NET_PKT
    mov ebx, ecx                        ; save payload length
    mov ecx, 6
    rep movsb                           ; dest MAC
    mov esi, our_mac
    mov ecx, 6
    rep movsb                           ; src MAC
    mov edx, eax
    xchg dl, dh
    mov [edi], dx
    add edi, 2

    mov ecx, ebx
    add ecx, 14
    mov esi, NET_PKT
    call rtl8139_send

    pop edi
    pop esi
    pop ecx
    pop ebx
    pop eax
    ret

; =============================================================================
; ip_send_payload - build IP header + checksum and transmit. Uses nd_* globals.
; =============================================================================
ip_send_payload:
    pusha
    mov edi, NET_PKT + 14
    mov byte [edi + 0], 0x45
    mov byte [edi + 1], 0x00
    mov eax, [nd_len]
    add eax, 20
    xchg al, ah
    mov [edi + 2], ax
    mov word [edi + 4], 0x0000
    mov word [edi + 6], 0x0000
    mov byte [edi + 8], 64
    mov eax, [nd_proto]
    mov [edi + 9], al
    mov word [edi + 10], 0x0000

    mov esi, our_ip
    lea ebx, [edi + 12]
    mov ecx, 4
.s1:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .s1
    mov esi, nd_ip
    mov ecx, 4
.s2:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .s2

    mov esi, NET_PKT + 14
    mov ecx, 20
    call checksum
    mov [NET_PKT + 14 + 10], ax

    mov esi, nd_mac
    mov eax, ETHER_IPV4
    mov ecx, [nd_len]
    add ecx, 20
    call net_send
    popa
    ret

nd_mac:  times 6 db 0
nd_ip:   times 4 db 0
nd_proto: dd 0
nd_len:   dd 0
ip_ihl:   dd 0

; =============================================================================
; net_poll - receive and dispatch.
; =============================================================================
net_poll:
    pusha
    mov edi, NET_RECV
    call rtl8139_receive
    test eax, eax
    jz .done

    mov esi, NET_RECV
    mov ax, [esi + 12]
    xchg al, ah
    cmp ax, ETHER_ARP
    je .arp
    cmp ax, ETHER_IPV4
    je .ip
    jmp .done
.arp:
    lea esi, [NET_RECV + 14]
    call arp_handle
    jmp .done
.ip:
    lea esi, [NET_RECV + 14]
    call ip_handle
.done:
    popa
    ret

; =============================================================================
; ARP reply.
; =============================================================================
arp_handle:
    mov ax, [esi + 6]
    xchg al, ah
    cmp ax, 1
    jne .done

    push esi
    add esi, 24                         ; tpa
    mov edi, our_ip
    mov ecx, 4
    repe cmpsb
    pop esi
    jne .done

    mov edi, NET_PKT + 14
    mov byte [edi + 0], 0x00
    mov byte [edi + 1], 0x01
    mov byte [edi + 2], 0x08
    mov byte [edi + 3], 0x00
    mov byte [edi + 4], 0x06
    mov byte [edi + 5], 0x04
    mov byte [edi + 6], 0x00
    mov byte [edi + 7], 0x02

    lea ebx, [edi + 8]
    mov esi, our_mac
    mov ecx, 6
.a1:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .a1
    mov esi, our_ip
    mov ecx, 4
.a2:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .a2
    mov esi, NET_RECV + 14 + 8          ; request sha
    mov ecx, 6
.a3:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .a3
    mov esi, NET_RECV + 14 + 14         ; request spa
    mov ecx, 4
.a4:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .a4

    mov esi, NET_RECV + 6
    mov eax, ETHER_ARP
    mov ecx, 28
    call net_send
.done:
    ret

; =============================================================================
; IPv4 dispatch.
; =============================================================================
ip_handle:
    mov al, [esi + 9]
    cmp al, IPPROTO_ICMP
    je .icmp
    cmp al, IPPROTO_UDP
    je .udp
    cmp al, IPPROTO_TCP
    je .tcp
    ret
.icmp:
    call icmp_handle
    ret
.udp:
    call udp_handle
    ret
.tcp:
    call tcp_handle
    ret

; =============================================================================
; ICMP echo reply.
; =============================================================================
icmp_handle:
    movzx eax, byte [esi]
    and eax, 0x0F
    shl eax, 2
    mov [ip_ihl], eax
    cmp byte [esi + eax], 8
    jne .done

    movzx ecx, word [esi + 2]
    xchg cl, ch
    sub ecx, eax
    mov [nd_len], ecx

    push esi
    add esi, eax
    mov edi, NET_PKT + 34
    mov ecx, [nd_len]
    rep movsb
    pop esi

    mov byte [NET_PKT + 34], 0
    mov word [NET_PKT + 34 + 2], 0
    push esi
    mov esi, NET_PKT + 34
    mov ecx, [nd_len]
    call checksum
    mov [NET_PKT + 34 + 2], ax
    pop esi

    mov esi, NET_RECV + 6
    mov edi, nd_mac
    mov ecx, 6
    rep movsb
    mov esi, NET_RECV + 14 + 12
    mov edi, nd_ip
    mov ecx, 4
    rep movsb

    mov dword [nd_proto], IPPROTO_ICMP
    call ip_send_payload
.done:
    ret

; =============================================================================
; UDP dispatch (DHCP replies).
; =============================================================================
udp_handle:
    movzx eax, byte [esi]
    and eax, 0x0F
    shl eax, 2
    add esi, eax                        ; UDP header
    mov ax, [esi + 2]
    xchg al, ah
    cmp ax, DHCP_CLIENT_PORT
    jne .done
    add esi, 8
    call dhcp_handle
.done:
    ret

; =============================================================================
; DHCP client.
; =============================================================================
dhcp_start:
    mov dword [dhcp_state], 0
    call dhcp_build_bootp
    mov esi, dhcp_op_discover
    call dhcp_append_opts
    call dhcp_send_broadcast
    ret

; dhcp_handle - ESI = BOOTP header.
dhcp_handle:
    cmp byte [esi], 2
    jne .done
    mov eax, [esi + 4]
    cmp eax, [dhcp_xid]
    jne .done

    ; locate option 53 (message type)
    mov [dhcp_bootp_ptr], esi
    add esi, 240
    call dhcp_find_type
    cmp al, 2
    je .offer
    cmp al, 5
    je .ack
    jmp .done

.offer:
    mov esi, [dhcp_bootp_ptr]
    ; save yiaddr (offered IP)
    mov eax, esi
    add eax, 16
    mov [offered_ip], eax
    ; save server id (option 54)
    push esi
    add esi, 240
    call dhcp_find_server
    pop esi
    call dhcp_send_request
    jmp .done

.ack:
    mov esi, [dhcp_bootp_ptr]
    ; our_ip = yiaddr
    mov eax, esi
    add eax, 16
    mov esi, eax
    mov edi, our_ip
    mov ecx, 4
    rep movsb

    ; extract gateway (option 3) and DNS (option 6)
    mov esi, [dhcp_bootp_ptr]
    add esi, 240
    call dhcp_find_opt3_6

    mov dword [dhcp_state], 3
    mov esi, msg_dhcp_ok
    call serial_write
    call print_our_ip
    mov esi, msg_dhcp_done
    call serial_write
.done:
    ret

; build the BOOTP header + magic cookie at NET_PKT+42.
dhcp_build_bootp:
    mov edi, NET_PKT + 42
    mov ecx, 512
    xor eax, eax
    rep stosd                           ; zero 2048 bytes
    mov edi, NET_PKT + 42
    mov byte [edi], 1
    mov byte [edi + 1], 1
    mov byte [edi + 2], 6
    mov eax, [dhcp_xid]
    mov [edi + 4], eax
    mov esi, our_mac
    lea ebx, [edi + 28]
    mov ecx, 6
.cp:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .cp
    mov dword [edi + 236], 0x63538263  ; magic 0x63825363 (LE)
    ret

; dhcp_append_opts - ESI = option bytes ending in 0xFF.
dhcp_append_opts:
    mov edi, NET_PKT + 42 + 240
.copy:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    cmp al, 0xFF
    jne .copy
    mov [dhcp_opt_end], edi
    ret

; dhcp_send_broadcast - build UDP header, set nd_*, send broadcast.
dhcp_send_broadcast:
    mov edi, NET_PKT + 34               ; UDP header
    mov byte [edi + 0], 0x00            ; src port 68
    mov byte [edi + 1], 68
    mov byte [edi + 2], 0x00            ; dst port 67
    mov byte [edi + 3], 67
    mov eax, [dhcp_opt_end]
    sub eax, NET_PKT + 34               ; UDP length (header + bootp + opts)
    xchg al, ah
    mov [edi + 4], ax
    mov word [edi + 6], 0x0000          ; no UDP checksum
    mov eax, [dhcp_opt_end]
    sub eax, NET_PKT + 34
    mov [nd_len], eax

    mov edi, nd_mac
    mov ecx, 6
    mov al, 0xFF
    rep stosb
    mov edi, nd_ip
    mov ecx, 4
    rep stosb
    mov dword [nd_proto], IPPROTO_UDP
    call ip_send_payload
    ret

; dhcp_send_request - build REQUEST.
dhcp_send_request:
    call dhcp_build_bootp
    mov edi, NET_PKT + 42 + 240
    mov byte [edi + 0], 53
    mov byte [edi + 1], 1
    mov byte [edi + 2], 3                ; REQUEST
    mov byte [edi + 3], 50
    mov byte [edi + 4], 4
    mov esi, [offered_ip]
    add esi, 0                            ; (offered_ip already points at yiaddr)
    mov ecx, 4
    lea ebx, [edi + 5]
.cp50:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .cp50
    mov byte [edi + 9], 54
    mov byte [edi + 10], 4
    lea ebx, [edi + 11]
    mov esi, dhcp_server_id
    mov ecx, 4
.cp54:
    mov al, [esi]
    mov [ebx], al
    inc esi
    inc ebx
    loop .cp54
    mov byte [edi + 15], 255
    lea eax, [edi + 16]
    mov [dhcp_opt_end], eax
    call dhcp_send_broadcast
    ret

; dhcp_find_type - ESI = options. Returns AL = message type.
dhcp_find_type:
.loop:
    mov al, [esi]
    cmp al, 255
    je .none
    cmp al, 53
    jne .skip
    mov al, [esi + 2]
    ret
.skip:
    movzx eax, byte [esi + 1]
    add esi, 2
    add esi, eax
    jmp .loop
.none:
    xor eax, eax
    ret

; dhcp_find_server - ESI = options. Copy option 54 to dhcp_server_id.
dhcp_find_server:
.loop:
    mov al, [esi]
    cmp al, 255
    je .none
    cmp al, 54
    jne .skip
    push esi
    add esi, 2
    mov edi, dhcp_server_id
    mov ecx, 4
    rep movsb
    pop esi
    ret
.skip:
    movzx eax, byte [esi + 1]
    add esi, 2
    add esi, eax
    jmp .loop
.none:
    ret

; dhcp_find_opt3_6 - ESI = options. Extract router (3) and DNS (6).
dhcp_find_opt3_6:
.loop:
    mov al, [esi]
    cmp al, 255
    je .none
    cmp al, 3
    je .router
    cmp al, 6
    je .dns
.skip:
    movzx eax, byte [esi + 1]
    add esi, 2
    add esi, eax
    jmp .loop
.router:
    push esi
    add esi, 2
    mov edi, gateway_ip
    mov ecx, 4
    rep movsb
    pop esi
    jmp .skip
.dns:
    push esi
    add esi, 2
    mov edi, dns_ip
    mov ecx, 4
    rep movsb
    pop esi
    jmp .skip
.none:
    ret

; print_our_ip - dotted decimal.
print_our_ip:
    push eax
    push ebx
    push ecx
    mov ecx, 4
    xor ebx, ebx
.loop:
    movzx eax, byte [our_ip + ebx]
    call print_dec
    inc ebx
    cmp ebx, 4
    jae .done
    mov al, '.'
    call serial_putchar
    jmp .loop
.done:
    pop ecx
    pop ebx
    pop eax
    ret

; print_dec - EAX = unsigned (< 1000).
print_dec:
    push ebx
    push ecx
    push edx
    mov ecx, 0
    mov ebx, 10
.dv:
    xor edx, edx
    div ebx
    push edx
    inc ecx
    test eax, eax
    jnz .dv
.w:
    pop eax
    add al, '0'
    call serial_putchar
    loop .w
    pop edx
    pop ecx
    pop ebx
    ret

dhcp_op_discover:
    db 53, 1, 1          ; DISCOVER
    db 55, 3, 1, 3, 6    ; request subnet, router, DNS
    db 255

dhcp_bootp_ptr: dd 0
offered_ip:     dd 0
dhcp_server_id: times 4 db 0
dhcp_opt_end:   dd 0

; =============================================================================
; TCP: minimal HTTP responder on port 80.
; =============================================================================
tcp_handle:
    movzx eax, byte [esi]
    and eax, 0x0F
    shl eax, 2
    add esi, eax                        ; TCP header

    mov ax, [esi + 2]
    xchg al, ah
    cmp ax, 80                          ; HTTP port?
    jne .done

    mov al, [esi + 13]                  ; flags
    test al, 0x02                       ; SYN?
    jnz .syn
    test al, 0x10                       ; ACK?
    jz .done
    call tcp_send_http
    jmp .done

.syn:
    ; record client seq and port
    mov eax, [esi + 4]                  ; seq (network order)
    bswap eax
    mov [tcp_client_seq], eax
    mov ax, [esi + 0]                   ; src port
    xchg al, ah
    movzx eax, ax
    mov [tcp_client_port], eax
    call tcp_send_synack
.done:
    ret

; tcp_send_synack - SYN/ACK to the client.
tcp_send_synack:
    ; build TCP header at NET_PKT+34 (no data)
    mov edi, NET_PKT + 34
    mov byte [edi + 0], 0x00
    mov byte [edi + 1], 80               ; src port 80
    mov eax, [tcp_client_port]
    xchg al, ah
    mov [edi + 2], ax                    ; dst port
    mov eax, [tcp_our_seq]
    bswap eax
    mov [edi + 4], eax                   ; seq
    mov eax, [tcp_client_seq]
    inc eax
    bswap eax
    mov [edi + 8], eax                   ; ack = client_seq + 1
    mov byte [edi + 12], 0x50            ; data offset 5
    mov byte [edi + 13], 0x12            ; SYN | ACK
    mov byte [edi + 14], 0x05            ; window 0x05B4
    mov byte [edi + 15], 0xB4
    mov word [edi + 16], 0x0000          ; checksum (0 for now)
    mov word [edi + 18], 0x0000          ; urgent pointer

    ; checksum over TCP header (20 bytes) + pseudo-header
    mov esi, NET_PKT + 34
    mov ecx, 20
    call tcp_checksum
    mov [NET_PKT + 34 + 16], ax

    mov dword [nd_len], 20               ; TCP segment length
    call tcp_set_nd_and_send
    ret

; tcp_send_http - respond with the HTML page + FIN.
tcp_send_http:
    ; build TCP header + data at NET_PKT+34
    mov edi, NET_PKT + 34
    mov byte [edi + 0], 0x00
    mov byte [edi + 1], 80
    mov eax, [tcp_client_port]
    xchg al, ah
    mov [edi + 2], ax
    mov eax, [tcp_our_seq]
    inc eax
    bswap eax
    mov [edi + 4], eax                   ; seq = our_seq + 1
    mov eax, [tcp_client_seq]
    inc eax
    bswap eax
    mov [edi + 8], eax                   ; ack = client_seq + 1
    mov byte [edi + 12], 0x50
    mov byte [edi + 13], 0x19            ; PSH | ACK | FIN (0x08|0x10|0x01)
    mov byte [edi + 14], 0x05
    mov byte [edi + 15], 0xB4
    mov word [edi + 16], 0x0000
    mov word [edi + 18], 0x0000          ; urgent pointer

    ; append HTTP response data
    lea edi, [NET_PKT + 34 + 20]
    mov esi, http_response
    mov ecx, http_response_len
    rep movsb

    ; total TCP segment length = 20 + data
    mov eax, 20
    add eax, http_response_len
    mov [nd_len], eax

    ; checksum
    mov esi, NET_PKT + 34
    mov ecx, [nd_len]
    call tcp_checksum
    mov [NET_PKT + 34 + 16], ax

    call tcp_set_nd_and_send
    mov esi, msg_http
    call serial_write
    ret

; tcp_checksum - ESI=segment, ECX=segment length. Uses client IP from NET_RECV.
; Returns AX.
tcp_checksum:
    push ebx
    push ecx
    push esi
    push edi

    mov ebx, ecx                        ; segment length
    mov edx, esi                        ; segment pointer

    mov edi, NET_SCRATCH
    mov esi, our_ip
    mov ecx, 4
    rep movsb                           ; src IP
    mov esi, NET_RECV + 14 + 12
    mov ecx, 4
    rep movsb                           ; dst IP (client)
    mov byte [edi], 0
    mov byte [edi + 1], IPPROTO_TCP
    add edi, 2
    mov eax, ebx
    xchg al, ah
    stosw                               ; TCP length
    mov esi, edx                        ; segment pointer
    mov ecx, ebx                        ; segment length
    rep movsb

    mov ecx, ebx
    add ecx, 12
    mov esi, NET_SCRATCH
    call checksum

    pop edi
    pop esi
    pop ecx
    pop ebx
    ret

; tcp_set_nd_and_send - set dest MAC/IP from NET_RECV, send.
tcp_set_nd_and_send:
    mov esi, NET_RECV + 6
    mov edi, nd_mac
    mov ecx, 6
    rep movsb
    mov esi, NET_RECV + 14 + 12
    mov edi, nd_ip
    mov ecx, 4
    rep movsb
    mov dword [nd_proto], IPPROTO_TCP
    call ip_send_payload
    ret

http_response:
    db "HTTP/1.1 200 OK", 0x0D, 0x0A
    db "Content-Type: text/html", 0x0D, 0x0A
    db 0x0D, 0x0A
    db "<html><body><h1>X86ASMOS</h1>"
    db "<p>Hello from a pure-assembly TCP/IP stack!</p>"
    db "</body></html>"
http_response_len equ $ - http_response

NET_SCRATCH equ 0x312000
