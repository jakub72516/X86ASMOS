# X86ASMOS — Technical Design Notes

## 1. Boot sequence

1. **Stage 1** (`src/boot/boot.asm`, 512 B, loaded at `0x7C00` by the BIOS):
   sets up segments/stack, resets the disk, and loads Stage 2 (16 sectors) to
   `0x8000` using CHS addressing.
2. **Stage 2** (`src/boot/stage2.asm`, at `0x8000`): enables A20, loads the
   kernel into a low staging buffer (`0x10000`) with LBA (or CHS fallback),
   queries the E820 memory map, selects an 800x600x32 VBE mode, switches to
   32-bit protected mode, copies the kernel up to `0x100000`, and jumps to it.
3. **Kernel** (`src/kernel/kernel.asm`, linked at `0x100000`): installs a
   flat GDT with TSS, builds an identity page map over the first 128 MiB,
   initialises the PMM/slab allocator, the PIC/IDT, the PIT-driven scheduler,
   the GUI/input/audio/filesystem/network subsystems, then spawns demo tasks.

> The kernel is loaded via a low-memory staging buffer because a BIOS disk
> read (`int 13h`) uses a 16:16 buffer pointer that cannot address above
> 1 MiB; the copy to `0x100000` happens after entering protected mode.

## 2. Memory map

| Range                  | Use                                   |
|------------------------|---------------------------------------|
| `0x000000–0x000FFF`    | IVT, BIOS data                         |
| `0x005000`             | Boot information block (magic, E820)   |
| `0x007C00`             | Stage 1                               |
| `0x008000`             | Stage 2                               |
| `0x010000`             | Staging buffer (boot only)             |
| `0x05610`             | Video info (width/height/bpp/pitch/fb) |
| `0x090000`             | Kernel / boot-task stack (grows down)  |
| `0x100000`             | Kernel image (text/data/bss)           |
| `0x200000`             | Page directory                         |
| `0x201000`             | Page tables (identity map, 128 MiB)    |
| `0x280000`             | PMM bitmap (4 KiB, 128 MiB)            |
| `0x300000`             | Network DMA buffers (RX ring 8 KiB @ 0x300000, TX @ 0x308000, packet assembly @ 0x310000) |
| `0x400000`+            | Free frames handed out by the PMM      |
| VBE linear framebuffer | Identity-mapped at runtime (e.g. `0xFD000000`) |

The kernel reserves everything below 4 MiB; the PMM tracks 4 KiB frames with
a bitmap (bit set = in use) and hands out frames above 4 MiB.

## 3. GDT / segments

| Selector | Descriptor        |
|----------|-------------------|
| `0x08`   | Kernel code (DPL 0) |
| `0x10`   | Kernel data (DPL 0) |
| `0x18`   | User code   (DPL 3) |
| `0x20`   | User data   (DPL 3) |
| `0x28`   | TSS (32-bit, ring-0 stack) |

## 4. Interrupts / IDT

Vectors 0–31 are CPU exceptions; 32–47 are the remapped PIC IRQs (master at
0x20, slave at 0x28); 0x80 is the syscall gate and 0x81 the scheduler-yield
gate (both DPL 3).

Every interrupt funnels through `isr_common`, which builds a 68-byte register
frame on the stack. Offsets from the frame base:

```
gs=0 fs=4 es=8 ds=12 edi=16 esi=20 ebp=24 esp=28
ebx=32 edx=36 ecx=40 eax=44 intnum=48 err=52 eip=56 cs=60 eflags=64
```

## 5. Scheduling

The PIT runs at ~100 Hz (IRQ0). Each task owns an 8 KiB kernel stack and a
TCB (`esp`, `next`, `state`, `sleep_until`, `pid`, `stack`, `msg_head`). The
scheduler is a round-robin circular run queue. A context switch only swaps the
stack pointer: the interrupt path saves a task's full frame, `schedule_switch`
saves ESP, picks the next READY task (waking any whose sleep deadline passed),
loads its ESP, and `isr_restore` pops the frame and `iret`s into it.

New tasks are given a synthetic frame whose `eip`/`cs`/`eflags` point at the
entry function, so the first switch "resumes" them as if interrupted.

## 6. System calls (`int 0x80`)

Calling convention: `EAX = syscall number`, `EBX/ECX/EDX = args`, result in
`EAX`.

| # | Syscall       | Args / result                                  |
|---|---------------|------------------------------------------------|
| 0 | `sys_print`    | `EBX` = string ptr → 0                          |
| 1 | `sys_tick`     | → tick count                                    |
| 2 | `sys_yield`    | → 0                                             |
| 3 | `sys_sleep`    | `EBX` = ticks → 0                               |
| 4 | `sys_ipc_send` | `EBX` = pid, `ECX` = message → 0/error         |
| 5 | `sys_ipc_recv` | → message (0xFFFFFFFF if empty)                 |
| 6 | `sys_print_hex`| `EBX` = value → 0                               |

## 7. Filesystem / disk layout

The raw image is 16 MiB, 512-byte sectors:

| LBA       | Contents                              |
|-----------|---------------------------------------|
| 0         | Stage 1 (boot sector)                 |
| 1–16      | Stage 2                               |
| 17–2047   | Kernel (padded; size passed at build) |
| 2048+     | FAT32 partition (formatted by `tools/mkfat32.py`) |

`tools/mkfat32.py` writes a minimal FAT32 (1-sector clusters, 2 FATs, 32
reserved sectors) with `README.TXT`, `INDEX.HTM`, and `HELLO.JIT`.

## 8. Networking

The RTL8139 is found via PCI, its MAC read, and TX/RX enabled. TX uses four
round-robin descriptors; RX uses an 8 KiB ring with a software read pointer
(CAPR is written with the chip's −16 quirk). The stack builds packets in a
fixed scratch buffer and implements ARP reply, IPv4 (with header checksum),
ICMP echo, UDP/DHCP (DISCOVER→OFFER→REQUEST→ACK), and a minimal TCP endpoint
on port 80 that answers a SYN with SYN/ACK and a GET with a fixed HTML page.
Checksums are the standard 16-bit one's-complement Internet checksum.

## 9. Build outputs

* `build/x86asmos.img` — 16 MiB raw disk (bootable, FAT32 partition).
* `build/x86asmos.iso` — El Torito CD (floppy-emulation boot of the first
  1.44 MiB).
