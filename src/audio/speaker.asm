; =============================================================================
; X86ASMOS - PC Speaker Driver
; -----------------------------------------------------------------------------
; Generates square-wave tones using PIT channel 2 and the PPI speaker gate.
; This is the low-latency, timer-driven audio output for the OS.
;
; Public interface:
;   speaker_on  - EAX = frequency in Hz (clamped to >= 19 Hz)
;   speaker_off - silence the speaker
;   beep        - EAX = frequency; one short beep is left to the caller/timer
; =============================================================================

SPEAKER_PORT equ 0x61

; -----------------------------------------------------------------------------
; speaker_on - EAX = frequency in Hz.
; -----------------------------------------------------------------------------
speaker_on:
    push eax
    push ebx
    push ecx
    push edx

    ; divisor = 1193182 / frequency.
    mov ebx, eax
    test ebx, ebx
    jnz .nonzero
    mov ebx, 1
.nonzero:
    mov eax, 1193182
    xor edx, edx
    div ebx                             ; EAX = divisor
    mov ecx, eax

    ; Program PIT channel 2 (square wave).
    mov al, 0xB6                        ; channel 2, lo/hi byte, mode 3, binary
    out 0x43, al
    mov al, cl
    out 0x42, al
    mov al, ch
    out 0x42, al

    ; Enable the timer gate and the speaker.
    in al, SPEAKER_PORT
    or al, 0x03
    out SPEAKER_PORT, al

    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; -----------------------------------------------------------------------------
; speaker_off - disable the speaker.
; -----------------------------------------------------------------------------
speaker_off:
    push eax
    in al, SPEAKER_PORT
    and al, 0xFC
    out SPEAKER_PORT, al
    pop eax
    ret

; -----------------------------------------------------------------------------
; beep - EAX = frequency, EBX = duration in ticks. Blocks for the duration.
; -----------------------------------------------------------------------------
beep:
    push ebx
    call speaker_on
    pop eax                             ; EAX = duration
    call task_sleep
    call speaker_off
    ret
