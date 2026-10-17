; =============================================================================
; X86ASMOS - System Call Interface (int 0x80)
; -----------------------------------------------------------------------------
; A tiny syscall ABI. User/kernel code invokes `int 0x80` with:
;   EAX = syscall number
;   EBX = argument 1
;   ECX = argument 2
;   EDX = argument 3
; The return value is placed in EAX.
;
; Syscall table:
;   0  sys_print      EBX = string ptr -> 0
;   1  sys_tick       -> current tick count
;   2  sys_yield      -> 0
;   3  sys_sleep      EBX = ticks -> 0
;   4  sys_ipc_send   EBX = pid, ECX = message -> 0/error
;   5  sys_ipc_recv   -> message (0xFFFFFFFF if empty)
;   6  sys_print_hex  EBX = value -> 0
; =============================================================================

SYS_PRINT     equ 0
SYS_TICK      equ 1
SYS_YIELD     equ 2
SYS_SLEEP     equ 3
SYS_IPC_SEND  equ 4
SYS_IPC_RECV  equ 5
SYS_PRINT_HEX equ 6
SYS_MAX       equ 7

; -----------------------------------------------------------------------------
; syscall_handler - called by isr_common with ESI = register frame.
; -----------------------------------------------------------------------------
syscall_handler:
    mov eax, [esi + REG_EAX]            ; syscall number
    cmp eax, SYS_MAX
    jae .done
    mov eax, [syscall_table + eax * 4]  ; handler address
    mov ebx, [esi + REG_EBX]            ; arg1
    mov ecx, [esi + REG_ECX]            ; arg2
    mov edx, [esi + REG_EDX]            ; arg3
    push esi
    call eax
    pop esi
    mov [esi + REG_EAX], eax            ; store return value
.done:
    ret

; --- individual syscalls ----------------------------------------------------

sys_print:
    push esi
    mov esi, ebx
    call serial_write
    pop esi
    xor eax, eax
    ret

sys_tick:
    mov eax, [tick_count]
    ret

sys_yield:
    call task_yield
    xor eax, eax
    ret

sys_sleep:
    push ebx
    mov eax, ebx
    call task_sleep
    pop ebx
    xor eax, eax
    ret

sys_ipc_send:
    mov eax, ebx
    mov ebx, ecx
    call ipc_send
    ret

sys_ipc_recv:
    call ipc_recv
    ret

sys_print_hex:
    mov eax, ebx
    call serial_write_hex
    xor eax, eax
    ret

; --- jump table -------------------------------------------------------------
syscall_table:
    dd sys_print
    dd sys_tick
    dd sys_yield
    dd sys_sleep
    dd sys_ipc_send
    dd sys_ipc_recv
    dd sys_print_hex
