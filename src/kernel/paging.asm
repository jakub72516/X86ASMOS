; =============================================================================
; X86ASMOS - Paging
; -----------------------------------------------------------------------------
; Sets up 4 KiB paging with a flat identity map over the supported physical
; range so that virtual addresses equal physical addresses for kernel and DMA
; work. Later subsystems (user mode, demand paging, JIT code) reuse map_page
; and unmap_page.
;
; Page structures live at fixed low addresses (below the 4 MiB reservation):
;   PAGE_DIR     0x200000   page directory (1024 PDEs)
;   PAGE_TABLES  0x201000   page tables for the identity map
;
; Page table flag bits:
;   PTE_PRESENT   1
;   PTE_WRITABLE  2
;   PTE_USER      4        (ring-3 accessible)
;
; Public interface:
;   paging_init    - identity-map IDENTITY_MAP_MB and enable paging
;   map_page       - EAX=pde base, EBX=virt, ECX=phys, EDX=flags
;   unmap_page     - EAX=pde base, EBX=virt
; =============================================================================

PAGE_DIR        equ 0x200000
PAGE_TABLES     equ 0x201000
IDENTITY_MAP_MB equ 128

PTE_PRESENT     equ 1
PTE_WRITABLE    equ 2
PTE_USER        equ 4

; -----------------------------------------------------------------------------
; paging_init - build the identity map and turn paging on.
; -----------------------------------------------------------------------------
paging_init:
    pusha

    mov edi, PAGE_DIR
    mov ecx, 1024
    xor eax, eax
    rep stosd                          ; zero page directory

    mov edi, PAGE_TABLES
    xor esi, esi                       ; physical address to map
    mov ecx, IDENTITY_MAP_MB * 256     ; pages = MB * 256
.ptes:
    mov eax, esi
    or eax, PTE_PRESENT | PTE_WRITABLE
    stosd
    add esi, 4096
    loop .ptes

    mov edi, PAGE_DIR
    mov esi, PAGE_TABLES
    mov ecx, IDENTITY_MAP_MB / 4       ; 4 MiB per PDE
.pdes:
    mov eax, esi
    or eax, PTE_PRESENT | PTE_WRITABLE
    stosd
    add esi, 4096
    loop .pdes

    mov eax, PAGE_DIR
    mov cr3, eax
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax

    popa
    ret

; -----------------------------------------------------------------------------
; map_page - map one 4 KiB page (allocating a page table if necessary).
;   EAX = page directory base (physical)
;   EBX = virtual address
;   ECX = physical address (4 KiB aligned)
;   EDX = flags (PTE_*)
; Returns EAX = 0 on success, 1 on out-of-memory.
; -----------------------------------------------------------------------------
map_page:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp

    mov ebp, eax                       ; EBP = page directory base
    mov esi, ebx
    shr esi, 22                        ; ESI = PDE index
    mov edi, ebx
    shr edi, 12
    and edi, 0x3FF                     ; EDI = PTE index

    mov eax, [ebp + esi * 4]           ; EAX = PDE
    test eax, PTE_PRESENT
    jnz .have_table

    ; No page table yet: allocate + zero a physical frame for it.
    call pmm_alloc_frame
    test eax, eax
    jz .fail

    push eax                           ; save table frame
    push edi                           ; save PTE index
    push ecx                           ; save physical address
    mov edi, eax                       ; zeroing destination
    mov ecx, 1024
    xor eax, eax
    rep stosd
    pop ecx                            ; restore physical address
    pop edi                            ; restore PTE index
    pop eax                            ; restore table frame

    or eax, PTE_PRESENT | PTE_WRITABLE | PTE_USER
    mov [ebp + esi * 4], eax           ; link PDE
    and eax, ~0xFFF                    ; EAX = table base
    jmp .write_pte

.have_table:
    and eax, ~0xFFF                    ; EAX = table base

.write_pte:
    mov edx, ecx                       ; EDX = physical address
    or edx, [esp + 12]                 ; OR in the original flags (pushed EDX)
    mov [eax + edi * 4], edx
    xor eax, eax                       ; success
    jmp .done

.fail:
    mov eax, 1                         ; out of memory
.done:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; unmap_page - clear a page table entry.
;   EAX = page directory base
;   EBX = virtual address
; -----------------------------------------------------------------------------
unmap_page:
    push ebx
    push esi
    push edi

    mov esi, ebx
    shr esi, 22                        ; PDE index
    mov edi, ebx
    shr edi, 12
    and edi, 0x3FF                     ; PTE index

    mov edx, [eax + esi * 4]           ; PDE
    test edx, PTE_PRESENT
    jz .done
    and edx, ~0xFFF                    ; table base
    mov dword [edx + edi * 4], 0       ; clear PTE
    mov eax, [esp + 8]                 ; recover the virtual address
    invlpg [eax]                       ; flush this page from the TLB

.done:
    pop edi
    pop esi
    pop ebx
    ret
