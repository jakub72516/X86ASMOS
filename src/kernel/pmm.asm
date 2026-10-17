; =============================================================================
; X86ASMOS - Physical Memory Manager (PMM)
; -----------------------------------------------------------------------------
; Tracks physical 4 KiB frames with a bitmap. Bit set (1) = frame in use,
; bit clear (0) = frame free. The bitmap lives at PMM_BITMAP and covers
; MAX_PHYS_MEM bytes (128 MiB by default).
;
; The kernel reserves everything below RESERVED_KERNEL_MEM (4 MiB) for its own
; code, paging structures, and the bitmap itself. Everything above that is
; handed out by pmm_alloc_frame.
;
; Public interface:
;   pmm_init          - parse the boot info E820 map and populate the bitmap
;   pmm_alloc_frame   - EAX = physical address of a free frame (0 if OOM)
;   pmm_free_frame    - EAX = physical address of the frame to release
;   pmm_used_frames   - EAX = number of frames currently allocated
;   pmm_total_frames  - EAX = number of usable frames
; =============================================================================

MAX_PHYS_MEM        equ 128 * 1024 * 1024      ; 128 MiB
PAGE_SIZE           equ 4096
MAX_FRAMES          equ MAX_PHYS_MEM / PAGE_SIZE
RESERVED_KERNEL_MEM equ 4 * 1024 * 1024        ; 4 MiB reserved for the kernel
PMM_BITMAP          equ 0x280000

E820_USABLE        equ 1

pmm_total:      dd 0        ; usable frame count
pmm_allocated:  dd 0        ; currently allocated count

; -----------------------------------------------------------------------------
; pmm_init - ESI = boot info block pointer. Builds the free list from E820.
; -----------------------------------------------------------------------------
pmm_init:
    pusha

    ; Zero the bitmap (all frames initially marked used).
    mov edi, PMM_BITMAP
    mov ecx, (MAX_FRAMES + 7) / 8 / 4
    mov eax, 0xFFFFFFFF
    rep stosd

    mov dword [pmm_total], 0
    mov dword [pmm_allocated], 0

    ; Iterate E820 entries, freeing usable regions that lie within our
    ; supported physical range.
    mov ecx, [esi + 4]                  ; entry count
    mov edi, esi
    add edi, 8                          ; first entry
    test ecx, ecx
    jz .done

.next_entry:
    cmp dword [edi + 16], E820_USABLE
    jne .skip

    ; base = [edi] (low) / [edi+4] (high); length = [edi+8]/[edi+12].
    cmp dword [edi + 4], 0              ; base high must be 0 (< 4 GiB)
    jne .skip
    mov eax, [edi]                      ; base
    mov ebx, [edi + 8]                  ; length low

    ; Clamp to MAX_PHYS_MEM.
    cmp eax, MAX_PHYS_MEM
    jae .skip
    ; end = base + length, clamp to MAX_PHYS_MEM
    mov edx, eax
    add edx, ebx
    jc .clamp
    cmp edx, MAX_PHYS_MEM
    jbe .have_end
.clamp:
    mov edx, MAX_PHYS_MEM
.have_end:
    ; Frame-align base up, end down.
    add eax, PAGE_SIZE - 1
    and eax, ~(PAGE_SIZE - 1)
    and edx, ~(PAGE_SIZE - 1)
    cmp eax, edx
    jae .skip

    ; Free frames [base, end).
.free_loop:
    push eax
    call _pmm_set_free
    pop eax
    inc dword [pmm_total]
    add eax, PAGE_SIZE
    cmp eax, edx
    jb .free_loop

.skip:
    add edi, 24
    dec ecx
    jnz .next_entry

.done:
    ; Reserve everything below RESERVED_KERNEL_MEM for the kernel.
    mov ecx, RESERVED_KERNEL_MEM / PAGE_SIZE
    xor eax, eax
.reserve_loop:
    push eax
    push ecx
    call _pmm_set_used
    pop ecx
    pop eax
    inc dword [pmm_allocated]
    add eax, PAGE_SIZE
    loop .reserve_loop

    popa
    ret

; -----------------------------------------------------------------------------
; pmm_alloc_frame - returns EAX = frame address (0 on out of memory).
; -----------------------------------------------------------------------------
pmm_alloc_frame:
    push ebx
    push ecx
    push edx
    push edi
    push esi

    mov edi, PMM_BITMAP
    xor ecx, ecx                        ; byte index

.scan:
    cmp ecx, (MAX_FRAMES + 7) / 8
    jae .oom
    movzx eax, byte [edi + ecx]
    cmp al, 0xFF                        ; any free bit in this byte?
    je .next_byte

    not eax                             ; 1 = free
    bsf ebx, eax                        ; EBX = bit index (0-7)

    ; frame index = ecx*8 + ebx
    mov edx, ecx
    shl edx, 3
    add edx, ebx                        ; EDX = frame index

    ; Mark it used: byte = frame>>3, bit = frame&7.
    mov eax, edx
    shr eax, 3                          ; byte index
    mov esi, edx
    and esi, 7                          ; bit offset
    mov ecx, esi
    mov ebx, 1
    shl ebx, cl                         ; EBX = 1 << bit
    or byte [PMM_BITMAP + eax], bl

    inc dword [pmm_allocated]

    ; Address = frame index * 4096.
    mov eax, edx
    shl eax, 12

    jmp .done

.next_byte:
    inc ecx
    jmp .scan

.oom:
    xor eax, eax
.done:
    pop esi
    pop edi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; pmm_free_frame - EAX = frame address to release.
; -----------------------------------------------------------------------------
pmm_free_frame:
    push eax
    call _pmm_set_free
    pop eax
    dec dword [pmm_allocated]
    ret

; --- internal helpers (do not preserve registers) ---------------------------

; _pmm_set_free - EAX = frame address; clears its bitmap bit.
_pmm_set_free:
    push eax
    push ecx
    push edx
    mov edx, eax
    shr edx, 12                         ; frame index
    mov eax, edx
    mov ecx, edx
    shr eax, 3
    and ecx, 7
    mov dl, 1
    shl dl, cl
    not dl
    and byte [PMM_BITMAP + eax], dl
    pop edx
    pop ecx
    pop eax
    ret

; _pmm_set_used - EAX = frame address; sets its bitmap bit.
_pmm_set_used:
    push ecx
    push edx
    mov edx, eax
    shr edx, 12
    mov eax, edx
    mov ecx, edx
    shr eax, 3
    and ecx, 7
    mov dl, 1
    shl dl, cl
    or byte [PMM_BITMAP + eax], dl
    pop edx
    pop ecx
    ret

; -----------------------------------------------------------------------------
pmm_used_frames:
    mov eax, [pmm_allocated]
    ret

pmm_total_frames:
    mov eax, [pmm_total]
    ret
