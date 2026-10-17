; =============================================================================
; X86ASMOS - Demo Tasks (Milestone 3 & 5)
; -----------------------------------------------------------------------------
; A couple of kernel threads that demonstrate pre-emptive round-robin
; scheduling, IPC, and the JIT scripting engine.
;
;   task_worker - arg in EAX = an ASCII character; prints "<ch><counter>"
;                 once per second, forever.
;   task_ipc    - blocks on ipc_recv and prints each message it receives.
;   task_jit    - compiles and runs two Brainfuck programs via the JIT.
; =============================================================================

; -----------------------------------------------------------------------------
; task_worker - EAX = character to print.
; -----------------------------------------------------------------------------
task_worker:
    mov ebx, eax                        ; EBX = character
    xor esi, esi                        ; ESI = counter
.loop:
    mov al, bl
    call serial_putchar
    mov eax, esi
    call serial_write_hex
    call serial_newline
    inc esi
    mov eax, 100                        ; sleep ~1 second
    call task_sleep
    jmp .loop

; -----------------------------------------------------------------------------
; task_ipc - receive and print IPC messages.
; -----------------------------------------------------------------------------
task_ipc:
.loop:
    call ipc_recv
    cmp eax, 0xFFFFFFFF
    je .sleep
    mov ebx, eax                        ; message value
    mov esi, msg_ipc_recv
    call serial_write
    mov eax, ebx
    call serial_write_hex
    call serial_newline
.sleep:
    mov eax, 5
    call task_sleep
    jmp .loop

; -----------------------------------------------------------------------------
; task_jit - demonstrate the Brainfuck JIT.
; -----------------------------------------------------------------------------
task_jit:
    mov esi, msg_jit
    call serial_write

    ; Program 1: print 'Z' (cell = 9 * 10 = 90).
    mov esi, bf_z
    call jit_run
    call serial_newline

    ; Program 2: "Hello World!".
    mov esi, bf_hello
    call jit_run
    call serial_newline

    mov esi, msg_jit_done
    call serial_write
    call task_exit

; -----------------------------------------------------------------------------
; task_music - plays a melody via the PC speaker and demonstrates the mixer.
; -----------------------------------------------------------------------------
task_music:
    mov esi, msg_music
    call serial_write

    ; Mixer demo: render a 3-note chord and dump a few samples.
    call mixer_init
    mov eax, 0
    mov ebx, 440
    mov ecx, 80
    call mixer_set_voice
    mov eax, 1
    mov ebx, 554
    mov ecx, 60
    call mixer_set_voice
    mov eax, 2
    mov ebx, 659
    mov ecx, 50
    call mixer_set_voice

    mov eax, mix_buf
    mov ecx, 512
    call mixer_render

    mov esi, msg_mix
    call serial_write
    mov ecx, 8
    mov esi, mix_buf
.mix_dump:
    movzx eax, byte [esi]
    call serial_write_hex
    inc esi
    loop .mix_dump
    call serial_newline

    ; Play the melody ("Twinkle Twinkle Little Star").
    mov esi, melody
.play:
    lodsd                               ; EAX = frequency (0 = end)
    test eax, eax
    jz .done
    call speaker_on
    push eax
    mov eax, 8                          ; note length (ticks)
    call task_sleep
    call speaker_off
    pop eax
    mov eax, 2                          ; gap between notes
    call task_sleep
    jmp .play

.done:
    call speaker_off
    mov esi, msg_music_done
    call serial_write
    call task_exit

; -----------------------------------------------------------------------------
; task_fs - list the FAT32 root directory, read a file, write a file.
; -----------------------------------------------------------------------------
task_fs:
    mov esi, msg_fs
    call serial_write

    ; List the root directory.
    mov esi, msg_fs_list
    call serial_write
    call fat32_list_dir

    ; Read README.TXT.
    mov esi, name_readme
    mov edi, fs_buf
    call fat32_read_file
    mov ecx, eax                        ; ECX = size
    mov esi, msg_fs_readme
    call serial_write
    mov esi, fs_buf
.print_readme:
    test ecx, ecx
    jz .after_read
    lodsb
    call serial_putchar
    dec ecx
    jmp .print_readme
.after_read:

    ; Write TEST.TXT and read it back.
    mov edi, fs_buf
    mov ecx, 256
    xor eax, eax
    rep stosd                           ; zero the buffer

    mov esi, fs_test_msg
    mov edi, fs_buf
    mov ecx, fs_test_msg_end - fs_test_msg - 1
.copy:
    mov al, [esi]
    mov [edi], al
    inc esi
    inc edi
    loop .copy

    mov esi, name_test
    mov edi, fs_buf
    mov ecx, fs_test_msg_end - fs_test_msg - 1
    call fat32_write_file

    mov esi, name_test
    mov edi, fs_buf
    call fat32_read_file
    mov ecx, eax
    mov esi, msg_fs_test
    call serial_write
    mov esi, fs_buf
.print_test:
    test ecx, ecx
    jz .done
    lodsb
    call serial_putchar
    dec ecx
    jmp .print_test
.done:
    call task_exit

msg_fs:       db "FAT32 test", 0x0A, 0
msg_fs_list:  db "Root directory:", 0x0A, 0
msg_fs_readme: db "README.TXT contents: ", 0
msg_fs_test:  db "TEST.TXT contents: ", 0

name_readme: db "README  TXT"
name_index:  db "INDEX   HTM"
name_test:   db "TEST    TXT"

fs_test_msg: db "Written by X86ASMOS FAT32 driver!", 0
fs_test_msg_end:

fs_buf: times 1024 db 0

; -----------------------------------------------------------------------------
; task_net - run the networking stack (DHCP + HTTP server).
; -----------------------------------------------------------------------------
task_net:
    call net_task

; -----------------------------------------------------------------------------
; task_syscall - exercise the int 0x80 syscall ABI.
; -----------------------------------------------------------------------------
task_syscall:
    mov eax, SYS_PRINT
    mov ebx, msg_syscall
    int 0x80
    mov eax, SYS_TICK
    int 0x80
    mov ebx, eax
    mov eax, SYS_PRINT_HEX
    int 0x80
    mov eax, SYS_PRINT
    mov ebx, msg_syscall_done
    int 0x80
    call task_exit

msg_syscall:      db "syscall tick=", 0
msg_syscall_done: db " via int 0x80", 0x0A, 0

msg_ipc_recv:   db "IPC recv=", 0
msg_jit:        db "JIT (Brainfuck -> x86): ", 0
msg_jit_done:   db "JIT done", 0x0A, 0
msg_music:      db "Music: mixing demo + melody", 0x0A, 0
msg_mix:        db "mix samples: ", 0
msg_music_done: db "Melody complete", 0x0A, 0

; C C G G A A G F F E E D D C
melody:
    dd 262, 262, 392, 392, 440, 440, 392, 349, 349, 330, 330, 294, 294, 262, 0

mix_buf: times 512 db 0


; Print 'Z' = 90 via a multiply loop (9 * 10).
bf_z:    db "+++++++++[>++++++++++<-]>.", 0

; Classic "Hello World!" (Wikipedia).
bf_hello: db "++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.", 0

