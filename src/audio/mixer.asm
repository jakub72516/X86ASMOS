; =============================================================================
; X86ASMOS - Software Audio Mixer
; -----------------------------------------------------------------------------
; Mixes up to 4 independent sine-wave voices into an 8-bit unsigned PCM
; stream. Each voice is a phase-accumulator oscillator reading a 256-entry
; sine table. The renderer scales and sums the voices (the "mix") and clamps
; the result. In a full AC'97 pipeline this buffer is DMA'd to the codec;
; here it doubles as the demonstration of the mixing stage.
;
; Voice state (10 bytes each):
;   +0 phase      dd  16.16 fixed-point phase
;   +4 increment  dd  16.16 phase increment per sample
;   +8 amplitude  db  0..255
;   +9 enabled    db  0/1
;
; Public interface:
;   mixer_init      - clear all voices
;   mixer_set_voice - EAX=index(0..3), EBX=freq, ECX=amplitude
;   mixer_render    - EAX=buffer, ECX=sample count
; =============================================================================

SAMPLE_RATE equ 44100
NUM_VOICES  equ 4

mixer_voices:
    times NUM_VOICES * 10 db 0

; -----------------------------------------------------------------------------
mixer_init:
    push eax
    push ecx
    push edi
    mov edi, mixer_voices
    mov ecx, NUM_VOICES * 10 / 4
    xor eax, eax
    rep stosd
    pop edi
    pop ecx
    pop eax
    ret

; -----------------------------------------------------------------------------
; mixer_set_voice - EAX=index, EBX=frequency, ECX=amplitude.
; -----------------------------------------------------------------------------
mixer_set_voice:
    push eax
    push ebx
    push ecx
    push edx
    push esi

    mov esi, eax
    imul esi, 10
    add esi, mixer_voices               ; ESI = voice pointer

    ; increment = (freq << 16) / SAMPLE_RATE
    mov eax, ebx
    shl eax, 16
    xor edx, edx
    mov ebx, SAMPLE_RATE
    div ebx                             ; EAX = increment (16.16)
    mov [esi + 4], eax

    mov [esi + 8], cl                   ; amplitude
    mov byte [esi + 9], 1               ; enabled

    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; -----------------------------------------------------------------------------
; mixer_render - EAX = destination buffer, ECX = number of samples.
; -----------------------------------------------------------------------------
mixer_render:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp

    mov esi, eax                        ; ESI = output buffer
    mov ecx, ecx                        ; ECX = sample count

.sample_loop:
    test ecx, ecx
    jz .done

    xor ebp, ebp                        ; EBP = mixed accumulator (signed sum)

    ; Loop over voices.
    mov ebx, 0                          ; voice index
    mov edi, mixer_voices               ; voice pointer

.voice_loop:
    cmp byte [edi + 9], 0               ; enabled?
    je .next_voice

    ; phase += increment
    mov eax, [edi + 4]
    add [edi + 0], eax

    ; index = (phase >> 8) & 0xFF
    mov eax, [edi + 0]
    shr eax, 8
    and eax, 0xFF
    movzx eax, byte [sine_table + eax]  ; 0..255
    sub eax, 128                        ; center to -128..127

    ; scale by amplitude (8-bit) -> keep upper byte as result
    movzx edx, byte [edi + 8]
    imul eax, edx                       ; signed multiply
    sar eax, 8                          ; scale back

    add ebp, eax                        ; accumulate

.next_voice:
    add edi, 10
    inc ebx
    cmp ebx, NUM_VOICES
    jb .voice_loop

    ; Clamp and center the result.
    add ebp, 128
    cmp ebp, 255
    jle .not_high
    mov ebp, 255
.not_high:
    cmp ebp, 0
    jge .store
    xor ebp, ebp
.store:
    mov eax, ebp
    mov [esi], al                       ; store 8-bit sample
    inc esi
    dec ecx
    jmp .sample_loop

.done:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; =============================================================================
; 256-entry sine table (0..255, centered at 128).
; =============================================================================
sine_table:
    db 128,131,134,137,140,144,147,150,153,156,159,162,165,168,171,174
    db 177,179,182,185,188,191,193,196,199,201,204,206,209,211,213,216
    db 218,220,222,224,226,228,230,232,234,235,237,239,240,241,243,244
    db 245,246,248,249,250,250,251,252,253,253,254,254,254,255,255,255
    db 255,255,255,255,254,254,254,253,253,252,251,250,250,249,248,246
    db 245,244,243,241,240,239,237,235,234,232,230,228,226,224,222,220
    db 218,216,213,211,209,206,204,201,199,196,193,191,188,185,182,179
    db 177,174,171,168,165,162,159,156,153,150,147,144,140,137,134,131
    db 128,125,122,119,116,112,109,106,103,100,97,94,91,88,85,82
    db 79,77,74,71,68,65,63,60,57,55,52,50,47,45,43,40
    db 38,36,34,32,30,28,26,24,22,21,19,17,16,15,13,12
    db 11,10,8,7,6,6,5,4,3,3,2,2,2,1,1,1
    db 1,1,1,1,2,2,2,3,3,4,5,6,6,7,8,10
    db 11,12,13,15,16,17,19,21,22,24,26,28,30,32,34,36
    db 38,40,43,45,47,50,52,55,57,60,63,65,68,71,74,77
    db 79,82,85,88,91,94,97,100,103,106,109,112,116,119,122,125
