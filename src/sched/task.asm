; =============================================================================
; X86ASMOS - Multitasking Scheduler & Tasks
; -----------------------------------------------------------------------------
; Pre-emptive round-robin scheduler driven by the PIT (IRQ0). Tasks are kernel
; threads running in ring 0 on their own private kernel stacks.
;
; Context switching is interrupt-driven and lean: the CPU and isr_common save
; a task's full register state as a 68-byte "frame" on its stack, so the
; scheduler only needs to swap the stack pointer (ESP) and let the shared
; isr_restore epilogue `iret` into the next task.
;
; Task frame layout (offsets from the frame base, matching idt.asm):
;   +0 gs +4 fs +8 es +12 ds +16 edi +20 esi +24 ebp +28 esp
;   +32 ebx +36 edx +40 ecx +44 eax +48 intnum +52 err
;   +56 eip +60 cs +64 eflags
;
; TCB layout:
;   +0  esp        kernel stack pointer (frame base)
;   +4  next       next TCB in the circular run queue
;   +8  state      0 = ready, 1 = sleeping, 2 = zombie
;   +12 sleep_until tick at which a sleeping task wakes (0 = awake)
;   +16 pid
;   +20 stack      base address of the task's stack (for freeing)
;   +24 msg_head   head of the task's IPC message queue (mailbox)
;
; Public interface:
;   scheduler_init - set up the boot task as the initial run queue
;   task_create    - EBX=entry, ECX=arg, EDX=name; returns EAX=pid
;   task_yield     - voluntarily yield the CPU (int 0x81)
;   task_sleep     - EAX=ticks; sleep for that many ticks
;   task_exit      - terminate the current task
;   timer_handler  - IRQ0 handler (EOI + tick + switch)
;   yield_handler  - int 0x81 handler (switch)
;   ipc_send       - EAX=pid, EBX=message value; enqueue a message
;   ipc_recv       - EAX = next message (blocking), 0xFFFFFFFF if none
; =============================================================================

TASK_STATE_READY    equ 0
TASK_STATE_SLEEPING equ 1
TASK_STATE_ZOMBIE   equ 2

TCB_ESP        equ 0
TCB_NEXT       equ 4
TCB_STATE      equ 8
TCB_SLEEP      equ 12
TCB_PID        equ 16
TCB_STACK      equ 20
TCB_MSG_HEAD   equ 24
TCB_SIZE       equ 28

TASK_STACK_SIZE equ 8192                ; 8 KiB per kernel thread
FRAME_SIZE     equ 68

current_task:  dd 0
tick_count:    dd 0
next_pid:      dd 1

; -----------------------------------------------------------------------------
; scheduler_init - create the TCB for the boot thread and make it current.
; -----------------------------------------------------------------------------
scheduler_init:
    pusha
    ; Allocate a TCB for the boot thread.
    mov eax, TCB_SIZE
    call kmalloc
    mov [current_task], eax
    mov ebx, eax
    mov dword [ebx + TCB_ESP], 0        ; set on first context switch
    mov dword [ebx + TCB_NEXT], ebx     ; self (circular)
    mov dword [ebx + TCB_STATE], TASK_STATE_READY
    mov dword [ebx + TCB_SLEEP], 0
    mov dword [ebx + TCB_PID], 0
    mov dword [ebx + TCB_STACK], 0
    mov dword [ebx + TCB_MSG_HEAD], 0
    mov dword [next_pid], 1
    mov dword [tick_count], 0
    popa
    ret

; -----------------------------------------------------------------------------
; task_create - EBX=entry, ECX=arg, EDX=name (unused for now).
; Returns EAX = pid.
; -----------------------------------------------------------------------------
task_create:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; Allocate a stack (8 KiB).
    push ebx
    push ecx
    push edx
    mov eax, TASK_STACK_SIZE
    call kmalloc
    mov edi, eax                        ; EDI = stack base
    pop edx
    pop ecx
    pop ebx
    test edi, edi
    jz .fail

    ; Allocate a TCB.
    push ebx
    push ecx
    push edx
    push edi
    mov eax, TCB_SIZE
    call kmalloc
    mov esi, eax                        ; ESI = TCB
    pop edi
    pop edx
    pop ecx
    pop ebx
    test esi, esi
    jz .fail

    ; Build the initial frame at the top of the stack.
    mov eax, edi
    add eax, TASK_STACK_SIZE            ; stack top
    sub eax, FRAME_SIZE                 ; frame base
    mov [esi + TCB_ESP], eax

    mov dword [eax + 0], KERNEL_DS      ; gs
    mov dword [eax + 4], KERNEL_DS      ; fs
    mov dword [eax + 8], KERNEL_DS      ; es
    mov dword [eax + 12], KERNEL_DS     ; ds
    mov dword [eax + 16], 0             ; edi
    mov dword [eax + 20], 0             ; esi
    mov dword [eax + 24], 0             ; ebp
    mov dword [eax + 28], 0             ; esp (unused)
    mov dword [eax + 32], 0             ; ebx
    mov dword [eax + 36], 0             ; edx
    mov dword [eax + 40], 0             ; ecx
    mov dword [eax + 44], ecx           ; eax = arg
    mov dword [eax + 48], 0             ; intnum
    mov dword [eax + 52], 0             ; err
    mov dword [eax + 56], ebx           ; eip = entry
    mov dword [eax + 60], KERNEL_CS     ; cs
    mov dword [eax + 64], 0x202         ; eflags (IF set)

    ; Fill TCB fields.
    mov dword [esi + TCB_STATE], TASK_STATE_READY
    mov dword [esi + TCB_SLEEP], 0
    mov eax, [next_pid]
    mov [esi + TCB_PID], eax
    inc dword [next_pid]
    mov [esi + TCB_STACK], edi
    mov dword [esi + TCB_MSG_HEAD], 0

    ; Insert into the circular run queue after the current task.
    mov ebx, [current_task]
    mov eax, [ebx + TCB_NEXT]
    mov [esi + TCB_NEXT], eax
    mov [ebx + TCB_NEXT], esi

    mov eax, [esi + TCB_PID]            ; return pid
    jmp .done

.fail:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; task_yield - voluntarily yield via int 0x81.
; -----------------------------------------------------------------------------
task_yield:
    int 0x81
    ret

; -----------------------------------------------------------------------------
; task_sleep - EAX = number of ticks to sleep. Preserves all other registers.
; -----------------------------------------------------------------------------
task_sleep:
    pusha
    cli
    mov ecx, [current_task]
    mov ebx, [tick_count]
    add ebx, eax
    mov [ecx + TCB_SLEEP], ebx
    mov dword [ecx + TCB_STATE], TASK_STATE_SLEEPING
    sti
    int 0x81                            ; yield until woken
    popa
    ret

; -----------------------------------------------------------------------------
; task_exit - terminate the current task.
; -----------------------------------------------------------------------------
task_exit:
    cli
    mov eax, [current_task]
    mov dword [eax + TCB_STATE], TASK_STATE_ZOMBIE
    int 0x81                            ; never returns to this task
.hang:
    hlt
    jmp .hang

; -----------------------------------------------------------------------------
; timer_handler - IRQ0. EOI, advance the tick, then context switch.
; Entered via `call` from irq_dispatch, so the stack has a return chain we
; skip with `add esp, 12` to reach the frame base.
; -----------------------------------------------------------------------------
timer_handler:
    mov al, 0x20
    out 0x20, al                        ; EOI to master PIC (IRQ0)

    inc dword [tick_count]

    add esp, 12                         ; skip return chain -> frame base
    jmp schedule_switch

; -----------------------------------------------------------------------------
; yield_handler - int 0x81. Entered via `jmp` from isr_common, so ESP already
; points at the frame base.
; -----------------------------------------------------------------------------
yield_handler:
    jmp schedule_switch

; -----------------------------------------------------------------------------
; schedule_switch - ESP must point at the frame base. Saves the current task,
; selects the next READY task (waking sleepers whose time is due), and jumps
; into isr_restore to resume it.
; -----------------------------------------------------------------------------
schedule_switch:
    mov eax, [current_task]
    mov [eax + TCB_ESP], esp            ; save current frame base

    mov eax, [eax + TCB_NEXT]           ; start from the next TCB
.find_next:
    cmp dword [eax + TCB_STATE], TASK_STATE_READY
    je .found
    cmp dword [eax + TCB_STATE], TASK_STATE_SLEEPING
    jne .skip                           ; zombie or other -> skip
    mov edx, [eax + TCB_SLEEP]
    mov ecx, [tick_count]
    cmp edx, ecx
    ja .skip                            ; still sleeping
    mov dword [eax + TCB_STATE], TASK_STATE_READY   ; wake it
    mov dword [eax + TCB_SLEEP], 0
    jmp .found
.skip:
    mov eax, [eax + TCB_NEXT]
    jmp .find_next
.found:
    mov [current_task], eax
    mov esp, [eax + TCB_ESP]            ; load the new task's frame base
    jmp isr_restore

; -----------------------------------------------------------------------------
; IPC: single-word mailbox per task.
;   ipc_send - EAX=pid, EBX=message word; returns EAX=0 success, 1 if no task.
;   ipc_recv - returns EAX=message word, or 0xFFFFFFFF if the queue is empty.
; -----------------------------------------------------------------------------
ipc_send:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; Locate the destination TCB by pid.
    mov ecx, [current_task]
    mov edx, ecx                        ; start of circular scan
.scan:
    cmp [ecx + TCB_PID], eax
    je .found_dest
    mov ecx, [ecx + TCB_NEXT]
    cmp ecx, edx
    jne .scan
    mov eax, 1                          ; destination not found
    jmp .done

.found_dest:
    ; Allocate a mailbox node (16 bytes via kmalloc 16-byte slab).
    push eax                            ; pid
    push ebx                            ; message
    mov eax, 16
    call kmalloc
    mov edi, eax
    pop ebx
    pop eax
    test edi, edi
    jz .fail_alloc

    mov [edi + 0], ebx                  ; message value
    mov ebx, [ecx + TCB_MSG_HEAD]
    mov [edi + 4], ebx                  ; link to previous head
    mov [ecx + TCB_MSG_HEAD], edi       ; new head
    xor eax, eax                        ; success
    jmp .done

.fail_alloc:
    mov eax, 2
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; -----------------------------------------------------------------------------
; ipc_recv - returns EAX = next message (0xFFFFFFFF if empty).
; -----------------------------------------------------------------------------
ipc_recv:
    push ebx
    push ecx

    mov ecx, [current_task]
    mov eax, [ecx + TCB_MSG_HEAD]
    test eax, eax
    jz .empty

    ; Pop the head node.
    mov ebx, [eax + 4]                  ; next node
    mov [ecx + TCB_MSG_HEAD], ebx
    mov ecx, [eax + 0]                  ; message value
    push ecx
    push eax
    ; Free the node.
    call kfree
    pop eax
    pop ecx
    mov eax, ecx                        ; return message value
    jmp .done

.empty:
    mov eax, 0xFFFFFFFF
.done:
    pop ecx
    pop ebx
    ret
