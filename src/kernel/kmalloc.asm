; =============================================================================
; X86ASMOS - Kernel Slab Allocator (kmalloc/kfree)
; -----------------------------------------------------------------------------
; A classic slab allocator: fixed-size object caches backed by 4 KiB pages
; obtained from the PMM. Each page ("slab") carries a small header, and free
; objects are threaded through a singly-linked list.
;
; Cache object sizes: 16, 32, 64, 128, 256, 512, 1024, 2048 bytes.
; Allocations larger than 2048 bytes fall back to a whole-page allocator that
; stores a small header before the returned pointer.
;
; Slab header (at the base of every slab page):
;   +0  magic       dd 0x42414C53 ("SLAB")
;   +4  cache       dd pointer to the owning cache struct
;   +8  next        dd next slab in the cache's list
;   +12 free_count  dd number of free objects in this slab
;   +16 free_head   dd first free object (0 if full)
;
; Large allocation header (at base of first page):
;   +0  magic       dd 0x4752414C ("LARG")
;   +4  pages       dd total pages (including header page)
;
; Public interface:
;   kmalloc_init - initialise the cache table
;   kmalloc      - EAX = size; returns EAX = pointer (0 on OOM)
;   kfree        - EAX = pointer; releases it
; =============================================================================

SLAB_HEADER_SIZE equ 32
MAGIC_SLAB      equ 0x42414C53
MAGIC_LARGE     equ 0x4752414C

NUM_CACHES       equ 8
CACHE_STRUCT_SIZE equ 16

CACHE_SIZE       equ 0
CACHE_SLABS      equ 4
CACHE_FREE       equ 8

SLAB_MAGIC       equ 0
SLAB_CACHE       equ 4
SLAB_NEXT        equ 8
SLAB_FREE_COUNT  equ 12
SLAB_FREE_HEAD   equ 16

align 4
cache_sizes: dd 16, 32, 64, 128, 256, 512, 1024, 2048

align 4
caches:
%assign i 0
%rep NUM_CACHES
    dd 0
    dd 0
    dd 0
    dd 0
%assign i i+1
%endrep

; -----------------------------------------------------------------------------
kmalloc_init:
    pusha
    mov ecx, NUM_CACHES
    xor edx, edx
.init_loop:
    mov eax, edx
    imul eax, CACHE_STRUCT_SIZE
    mov ebx, [cache_sizes + edx * 4]
    mov [caches + eax + CACHE_SIZE], ebx
    mov dword [caches + eax + CACHE_SLABS], 0
    mov dword [caches + eax + CACHE_FREE], 0
    inc edx
    loop .init_loop
    popa
    ret

; -----------------------------------------------------------------------------
; kmalloc - EAX = size. Returns EAX = pointer (0 on OOM).
; -----------------------------------------------------------------------------
kmalloc:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    cmp eax, 2048
    ja kmalloc_large

    ; Find the smallest cache that fits.
    xor ecx, ecx
.find_cache:
    cmp eax, [cache_sizes + ecx * 4]
    jbe .found
    inc ecx
    jmp .find_cache
.found:
    mov ebx, ecx
    imul ebx, CACHE_STRUCT_SIZE
    add ebx, caches                     ; EBX = cache struct

    ; Look for a slab with free objects.
    mov esi, [ebx + CACHE_SLABS]
.walk:
    test esi, esi
    jz .new_slab
    cmp dword [esi + SLAB_FREE_COUNT], 0
    jne .pop
    mov esi, [esi + SLAB_NEXT]
    jmp .walk

.pop:
    call slab_pop                       ; ESI = slab -> EAX = object
    jmp .done

.new_slab:
    call slab_create                    ; EBX = cache -> EAX = slab base
    test eax, eax
    jz .oom
    mov esi, eax
    call slab_pop
    jmp .done

.oom:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; slab_create - allocate and initialise a new slab for the cache in EBX.
; Returns EAX = slab page base (0 on OOM).
; -----------------------------------------------------------------------------
slab_create:
    push ecx
    push edx
    push esi
    push edi

    call pmm_alloc_frame
    test eax, eax
    jz .oom
    mov edi, eax                        ; EDI = slab base

    mov dword [edi + SLAB_MAGIC], MAGIC_SLAB
    mov dword [edi + SLAB_CACHE], ebx
    mov eax, [ebx + CACHE_SLABS]
    mov [edi + SLAB_NEXT], eax
    mov [ebx + CACHE_SLABS], edi        ; head insertion

    ; object count = (4096 - header) / object_size
    mov eax, [ebx + CACHE_SIZE]
    mov esi, 4096 - SLAB_HEADER_SIZE
    xor edx, edx
    div eax
    mov ecx, eax                        ; ECX = object count
    mov [edi + SLAB_FREE_COUNT], eax
    add dword [ebx + CACHE_FREE], eax

    ; Thread the free list.
    mov edx, edi
    add edx, SLAB_HEADER_SIZE           ; EDX = first object
    mov [edi + SLAB_FREE_HEAD], edx
    mov esi, [ebx + CACHE_SIZE]         ; ESI = object size
.thread:
    mov eax, edx
    add eax, esi                        ; next object address
    dec ecx
    jz .last
    mov [edx], eax
    mov edx, eax
    jmp .thread
.last:
    mov dword [edx], 0

    mov eax, edi                        ; return slab base
    jmp .done
.oom:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    ret

; -----------------------------------------------------------------------------
; slab_pop - pop one free object from the slab in ESI (cache in EBX).
; Returns EAX = object pointer.
; -----------------------------------------------------------------------------
slab_pop:
    mov eax, [esi + SLAB_FREE_HEAD]
    mov edx, [eax]                      ; next free object
    mov [esi + SLAB_FREE_HEAD], edx
    dec dword [esi + SLAB_FREE_COUNT]
    dec dword [ebx + CACHE_FREE]
    ret

; -----------------------------------------------------------------------------
; kmalloc_large - EAX = size (> 2048). Allocates whole pages with a header.
; -----------------------------------------------------------------------------
kmalloc_large:
    add eax, 16 + 4095
    and eax, ~4095                      ; total bytes (page aligned)
    mov ecx, eax
    shr ecx, 12                         ; ECX = total pages

    mov edi, 0
    mov esi, ecx
.alloc_pages:
    push esi
    push edi
    call pmm_alloc_frame
    pop edi
    pop esi
    test eax, eax
    jz .large_oom
    test edi, edi
    jnz .have_first
    mov edi, eax                        ; remember first page base
.have_first:
    dec esi
    jnz .alloc_pages

    mov dword [edi], MAGIC_LARGE
    mov dword [edi + 4], ecx            ; total pages
    mov eax, edi
    add eax, 16                         ; return pointer past header
    jmp .large_done

.large_oom:
    ; Simplification: already-allocated pages leak on OOM.
    xor eax, eax
.large_done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; kfree - EAX = pointer.
; -----------------------------------------------------------------------------
kfree:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov edi, eax
    and edi, ~4095                      ; page base
    mov ebx, [edi]                      ; magic

    cmp ebx, MAGIC_SLAB
    je .slab_free
    cmp ebx, MAGIC_LARGE
    je .large_free
    jmp .done                           ; unknown pointer: ignore

.slab_free:
    mov esi, [edi + SLAB_CACHE]         ; owning cache
    mov edx, [edi + SLAB_FREE_HEAD]
    mov [eax], edx                      ; *ptr = old head
    mov [edi + SLAB_FREE_HEAD], eax     ; head = ptr
    inc dword [edi + SLAB_FREE_COUNT]
    inc dword [esi + CACHE_FREE]
    jmp .done

.large_free:
    mov ecx, [edi + 4]                  ; total pages
.large_loop:
    push ecx
    push edi
    mov eax, edi
    call pmm_free_frame
    pop edi
    pop ecx
    add edi, 4096
    loop .large_loop
    jmp .done

.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
