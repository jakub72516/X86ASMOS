# X86ASMOS

A fully-featured 32-bit operating system written **entirely in x86 assembly**
(NASM). No C, no runtime libraries, no high-level scaffolding — every driver,
allocator, scheduler, and protocol is hand-crafted.

X86ASMOS boots from a disk image or CD, switches to protected mode, brings up
paging, pre-emptive multitasking, a double-buffered VESA GUI, a JIT-compiled
scripting engine, real-time audio, a FAT32 filesystem, and a TCP/IP stack that
DHCPs an address and serves a web page over HTTP.

## Feature matrix

| Subsystem          | Implementation                                   |
|--------------------|---------------------------------------------------|
| Bootloader         | Stage 1 (CHS) + Stage 2 (A20, E820, VBE, PM)      |
| Memory             | Bitmap PMM, paging, slab allocator (kmalloc)      |
| Multitasking       | Pre-emptive round-robin, sleep/wakeup, IPC mailbox |
| GUI                | VBE 800x600x32, double buffering, 8x8 font        |
| Input              | PS/2 keyboard (scancode set 1) + PS/2 mouse        |
| JIT                | Brainfuck -> native x86 compiler                  |
| Audio              | PC speaker tones + 4-voice software mixer          |
| Filesystem         | FAT32 read/write over ATA PIO                     |
| Networking         | RTL8139, ARP, IPv4, ICMP, UDP, DHCP, TCP, HTTP    |
| System calls       | `int 0x80` with 7 syscalls                        |

## Requirements

* [NASM](https://www.nasm.us/) (tested with 2.16 / 3.02)
* [Python 3](https://www.python.org/) (for the FAT32 formatter and ISO builder)
* [QEMU](https://www.qemu.org/) (recommended for testing)

## Building

### Windows (PowerShell)

```powershell
.\build.ps1              # assemble + build x86asmos.img + x86asmos.iso
.\build.ps1 -run         # build and boot in QEMU
.\build.ps1 -run serial  # build and boot with serial on stdio
.\build.ps1 -clean       # remove build artifacts
```

`build.ps1` locates NASM automatically (check `Find-Nasm` if yours is
elsewhere).

### Linux / macOS

```sh
make                     # build x86asmos.img + x86asmos.iso
make run                 # boot in QEMU (graphical)
make run-serial          # boot in QEMU (serial console)
```

## Running

Boot the raw disk image (has the FAT32 partition):

```sh
qemu-system-i386 -m 128M \
  -drive format=raw,file=build/x86asmos.img,if=ide \
  -netdev user,id=n0,hostfwd=tcp::8080-:80 \
  -device rtl8139,netdev=n0 \
  -serial file:build/serial.log
```

Boot the CD image:

```sh
qemu-system-i386 -m 128M -cdrom build/x86asmos.iso -serial stdio
```

When the networking task runs, it DHCPs an address (e.g. `10.0.2.15` under
QEMU's user-mode network) and starts an HTTP server on port 80. With the
`hostfwd` above, browse to <http://127.0.0.1:8080/> to fetch the page served
by the pure-assembly TCP stack.

## Repository layout

```
src/boot/     boot.asm (stage 1), stage2.asm (stage 2)
src/kernel/   kernel.asm (entry), vga, serial, gdt, idt, pic, pmm, paging,
              kmalloc, syscall
src/sched/    task.asm (TCB, scheduler, IPC)
src/drivers/  pit, keyboard, mouse, ata
src/fs/       fat32.asm
src/gui/      gfx.asm (framebuffer + font), gui.asm (desktop)
src/audio/    speaker.asm (PC speaker), mixer.asm (software mixer)
src/jit/      jit.asm (Brainfuck -> x86)
src/net/      pci.asm, rtl8139.asm, net.asm (TCP/IP stack)
src/user/     demo.asm (demo tasks)
tools/        mkfat32.py (FAT32 formatter), mkiso.py (El Torito ISO)
docs/         design notes and memory map
```

## Documentation

* [Design notes](docs/design.md) — architecture, memory map, syscall table,
  build/layout details.

## Limitations

* The kernel is 32-bit protected mode (no long mode / UEFI runtime; it boots
  on legacy BIOS and UEFI in CSM mode).
* The FAT32 driver assumes a hard disk; booting the CD image with no disk
  still boots the kernel but skips the FAT32 demo.
* The TCP endpoint is intentionally minimal (serves a fixed HTTP response).
