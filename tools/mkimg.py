#!/usr/bin/env python3
"""mkimg.py - assemble the raw disk image from boot/stage2/kernel binaries.

Mirrors the image layout in build.ps1: boot (1 sector) + stage2 (16 sectors)
+ kernel (KERNEL_SECTORS sectors, padded) + free space up to 16 MiB.

Usage: python tools/mkimg.py <out.img> <boot.bin> <stage2.bin> <kernel.bin>
"""

import sys

KERNEL_LBA_START = 17
KERNEL_SECTORS = 2032
TOTAL_SECTORS = 32768


def main(out, boot, stage2, kernel):
    with open(boot, 'rb') as f:
        boot_data = f.read()
    with open(stage2, 'rb') as f:
        stage2_data = f.read()
    with open(kernel, 'rb') as f:
        kernel_data = f.read()

    if len(kernel_data) > KERNEL_SECTORS * 512:
        raise SystemExit(f"kernel too large: {len(kernel_data)} bytes")

    img = bytearray()
    img += boot_data.ljust(512, b'\x00')
    img += stage2_data.ljust(16 * 512, b'\x00')
    img += kernel_data.ljust(KERNEL_SECTORS * 512, b'\x00')
    img += b'\x00' * (TOTAL_SECTORS * 512 - len(img))

    with open(out, 'wb') as f:
        f.write(img)
    print(f"image: {out} ({len(img)} bytes)")


if __name__ == '__main__':
    if len(sys.argv) != 5:
        print("usage: mkimg.py <out.img> <boot.bin> <stage2.bin> <kernel.bin>")
        sys.exit(1)
    main(*sys.argv[1:])
