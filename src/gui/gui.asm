; =============================================================================
; X86ASMOS - Desktop GUI (Milestone 4)
; -----------------------------------------------------------------------------
; Renders a simple desktop to the back buffer (title bar, two windows, a live
; clock, and a status bar) and blits it to the framebuffer. Called from the
; boot/idle task at a throttled rate.
;
; Public interface:
;   gui_render - draw the full desktop and blit it
; =============================================================================

COL_BG        equ 0x00162233
COL_TITLEBAR  equ 0x002B3E55
COL_WIN_BG    equ 0x001E3045
COL_WIN_TITLE equ 0x003A5070
COL_BORDER    equ 0x006080A0
COL_TEXT      equ 0x00E8E8E8
COL_ACCENT    equ 0x0028C0A0

; -----------------------------------------------------------------------------
; gui_render - draw everything and blit.
; -----------------------------------------------------------------------------
gui_render:
    pusha

    ; Desktop background.
    mov eax, 0
    mov ebx, 0
    mov ecx, [gfx_width]
    mov edx, [gfx_height]
    mov esi, COL_BG
    call gfx_fillrect

    ; Title bar.
    mov eax, 0
    mov ebx, 0
    mov ecx, [gfx_width]
    mov edx, 28
    mov esi, COL_TITLEBAR
    call gfx_fillrect

    mov eax, 12
    mov ebx, 6
    mov esi, msg_title
    mov edx, COL_TEXT
    call gfx_string

    call draw_clock

    ; Window 1: Terminal.
    mov eax, 24
    mov ebx, 60
    mov ecx, 460
    mov edx, 240
    mov esi, msg_win_term
    call draw_window
    mov eax, 40
    mov ebx, 108
    mov esi, msg_term1
    mov edx, COL_TEXT
    call gfx_string
    mov eax, 40
    mov ebx, 132
    mov esi, msg_term2
    mov edx, COL_TEXT
    call gfx_string
    mov eax, 40
    mov ebx, 156
    mov esi, msg_term3
    mov edx, COL_ACCENT
    call gfx_string

    ; Window 2: System info.
    mov eax, 500
    mov ebx, 60
    mov ecx, 276
    mov edx, 200
    mov esi, msg_win_sys
    call draw_window
    mov eax, 516
    mov ebx, 108
    mov esi, msg_sys1
    mov edx, COL_TEXT
    call gfx_string
    mov eax, 516
    mov ebx, 132
    mov esi, msg_sys2
    mov edx, COL_TEXT
    call gfx_string
    mov eax, 516
    mov ebx, 156
    mov esi, msg_sys3
    mov edx, COL_TEXT
    call gfx_string

    ; Status bar.
    mov eax, 0
    mov ebx, [gfx_height]
    sub ebx, 24
    mov ecx, [gfx_width]
    mov edx, 24
    mov esi, COL_TITLEBAR
    call gfx_fillrect

    mov eax, 12
    mov ebx, [gfx_height]
    sub ebx, 18
    mov esi, msg_status
    mov edx, COL_TEXT
    call gfx_string

    call draw_cursor

    call gfx_blit
    popa
    ret

; -----------------------------------------------------------------------------
; draw_cursor - draw a small cross cursor at the mouse position.
; -----------------------------------------------------------------------------
draw_cursor:
    pusha

    ; Horizontal bar.
    mov eax, [mouse_x]
    sub eax, 4
    mov ebx, [mouse_y]
    mov ecx, 9
    mov edx, 1
    mov esi, COL_ACCENT
    call gfx_fillrect

    ; Vertical bar.
    mov eax, [mouse_x]
    mov ebx, [mouse_y]
    sub ebx, 4
    mov ecx, 1
    mov edx, 9
    mov esi, COL_ACCENT
    call gfx_fillrect

    popa
    ret

; -----------------------------------------------------------------------------
; draw_window - EAX=x, EBX=y, ECX=w, EDX=h, ESI=title string.
; -----------------------------------------------------------------------------
draw_window:
    push eax                            ; [esp+16] x
    push ebx                            ; [esp+12] y
    push ecx                            ; [esp+8]  w
    push edx                            ; [esp+4]  h
    push esi                            ; [esp+0]  title

    ; Window body.
    mov esi, COL_WIN_BG
    call gfx_fillrect

    ; Title bar (height 24).
    mov eax, [esp+16]
    mov ebx, [esp+12]
    mov ecx, [esp+8]
    mov edx, 24
    mov esi, COL_WIN_TITLE
    call gfx_fillrect

    ; Title text.
    mov eax, [esp+16]
    add eax, 8
    mov ebx, [esp+12]
    add ebx, 4
    mov esi, [esp+0]
    mov edx, COL_TEXT
    call gfx_string

    ; Border.
    mov eax, [esp+16]
    mov ebx, [esp+12]
    mov ecx, [esp+8]
    mov edx, [esp+4]
    mov esi, COL_BORDER
    call gfx_rect

    add esp, 20
    ret

; -----------------------------------------------------------------------------
; draw_clock - format and draw the uptime clock (MM:SS).
; -----------------------------------------------------------------------------
draw_clock:
    pusha

    mov eax, [tick_count]
    xor edx, edx
    mov ebx, 100                        ; ticks per second
    div ebx                             ; EAX = seconds
    xor edx, edx
    mov ebx, 60
    div ebx                             ; EAX = minutes, EDX = seconds
    push edx                            ; seconds

    mov edi, clock_buf
    call format_dec2                    ; minutes
    mov byte [clock_buf + 2], ':'
    pop eax
    mov edi, clock_buf + 3
    call format_dec2                    ; seconds
    mov byte [clock_buf + 5], 0

    mov eax, [gfx_width]
    sub eax, 64                         ; right-align 8 chars
    mov ebx, 6
    mov esi, clock_buf
    mov edx, COL_TEXT
    call gfx_string

    popa
    ret

; -----------------------------------------------------------------------------
; format_dec2 - EAX = value (0..99), EDI = buffer; writes 2 zero-padded digits.
; -----------------------------------------------------------------------------
format_dec2:
    push eax
    push ebx
    push edx
    xor edx, edx
    mov ebx, 10
    div ebx                             ; EAX = tens, EDX = ones
    add al, '0'
    add dl, '0'
    mov [edi], al
    mov [edi + 1], dl
    pop edx
    pop ebx
    pop eax
    ret

msg_title:     db "X86ASMOS", 0
msg_win_term:  db "Terminal", 0
msg_win_sys:   db "System", 0
msg_term1:     db "$ x86asmos --about", 0
msg_term2:     db "Pure-assembly 32-bit OS", 0
msg_term3:     db "> kernel threads: 4", 0
msg_sys1:      db "CPU: x86 protected mode", 0
msg_sys2:      db "Video: 800x600x32 VBE", 0
msg_sys3:      db "Scheduler: round-robin", 0
msg_status:    db "Ready - preemptive multitasking + GUI", 0

clock_buf:     db "00:00", 0
