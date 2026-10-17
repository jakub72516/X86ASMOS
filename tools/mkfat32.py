#!/usr/bin/env python3
"""mkfat32.py - format the X86ASMOS disk image with a minimal FAT32 filesystem.

Creates a FAT32 partition starting at a fixed LBA (2048) and places a small
set of demo files in the root directory. Used by the kernel's FAT32 driver
for testing read/write.

Usage: python tools/mkfat32.py <image> [--files name=path ...]
"""

import struct
import sys

SECTOR = 512
SPC = 1                 # sectors per cluster (simplifies cluster<->sector math)
RESERVED = 32
NUM_FATS = 2
ROOT_CLUSTER = 2


def make_entry(name, ext, attr, cluster, size):
    """Build a 32-byte FAT32 directory entry."""
    e = bytearray(32)
    e[0:8] = name.encode('ascii').ljust(8, b' ')[:8]
    e[8:11] = ext.encode('ascii').ljust(3, b' ')[:3]
    e[11] = attr
    # creation/access/modify times: use a fixed timestamp (2020-01-01 00:00)
    e[13] = 0
    struct.pack_into('<H', e, 14, 0x0000)  # creation time 00:00
    struct.pack_into('<H', e, 16, 0x5380)  # creation date (2020-01-01)
    struct.pack_into('<H', e, 18, 0x5380)  # access date
    struct.pack_into('<H', e, 20, (cluster >> 16) & 0xFFFF)  # cluster high
    struct.pack_into('<H', e, 22, 0x0000)  # write time
    struct.pack_into('<H', e, 24, 0x5380)  # write date
    struct.pack_into('<H', e, 26, cluster & 0xFFFF)          # cluster low
    struct.pack_into('<I', e, 28, size)   # file size
    return e


def format_image(path, part_start, files):
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    part_bytes = len(data) - part_start * SECTOR
    total_sectors = part_bytes // SECTOR
    total_clusters = total_sectors // SPC
    fat_size = (total_clusters * 4 + SECTOR - 1) // SECTOR
    data_start = RESERVED + NUM_FATS * fat_size

    def wsect(lba, buf):
        off = (part_start + lba) * SECTOR
        data[off:off + len(buf)] = buf

    # ---- Boot sector (BPB) ----
    boot = bytearray(SECTOR)
    boot[0:3] = b'\xEB\x58\x90'            # jmp short + nop
    boot[3:11] = b'X86ASMOS'               # OEM name
    struct.pack_into('<H', boot, 11, SECTOR)   # bytes per sector
    boot[13] = SPC                         # sectors per cluster
    struct.pack_into('<H', boot, 14, RESERVED)  # reserved sectors
    boot[16] = NUM_FATS                    # number of FATs
    struct.pack_into('<H', boot, 17, 0)    # root entries (0 for FAT32)
    struct.pack_into('<H', boot, 19, 0)    # total sectors 16 (0 => use 32)
    boot[21] = 0xF8                        # media descriptor
    struct.pack_into('<H', boot, 22, 0)    # sectors per FAT 16 (0 for FAT32)
    struct.pack_into('<H', boot, 24, 63)   # sectors per track
    struct.pack_into('<H', boot, 26, 16)   # number of heads
    struct.pack_into('<I', boot, 28, 0)    # hidden sectors
    struct.pack_into('<I', boot, 32, total_sectors)  # total sectors 32
    struct.pack_into('<I', boot, 36, fat_size)       # FAT size 32
    struct.pack_into('<H', boot, 40, 0)    # ext flags
    struct.pack_into('<H', boot, 42, 0)    # fs version
    struct.pack_into('<I', boot, 44, ROOT_CLUSTER)   # root cluster
    struct.pack_into('<H', boot, 48, 1)    # FSInfo sector
    struct.pack_into('<H', boot, 50, 6)    # backup boot sector
    boot[64] = 0x80                        # drive number
    boot[66] = 0x29                        # ext boot signature
    struct.pack_into('<I', boot, 67, 0x58415358)  # volume serial "XASX"
    boot[71:82] = b'X86ASMOS   '           # volume label
    boot[82:90] = b'FAT32   '              # fs type
    boot[510:512] = b'\x55\xAA'
    wsect(0, boot)

    # ---- FSInfo sector ----
    fsinfo = bytearray(SECTOR)
    struct.pack_into('<I', fsinfo, 0, 0x41615252)   # lead signature
    struct.pack_into('<I', fsinfo, 484, 0x61417272) # struct signature
    struct.pack_into('<I', fsinfo, 488, 0xFFFFFFFF) # free cluster count (unknown)
    struct.pack_into('<I', fsinfo, 492, ROOT_CLUSTER + len(files))  # next free
    struct.pack_into('<I', fsinfo, 508, 0xAA550000)  # trail signature
    wsect(1, fsinfo)

    # ---- FATs ----
    fat = bytearray(fat_size * SECTOR)
    # cluster 0/1 reserved markers
    fat[0:4] = struct.pack('<I', 0x0FFFFFF8)
    fat[4:8] = struct.pack('<I', 0x0FFFFFFF)
    wsect(RESERVED, fat)
    wsect(RESERVED + fat_size, fat)  # second FAT copy

    # ---- Root directory ----
    root = bytearray(SECTOR)
    # volume label entry
    vl = bytearray(32)
    vl[0:11] = b'X86ASMOS   '
    vl[11] = 0x08                        # volume label attribute
    root[0:32] = vl
    wsect(data_start + (ROOT_CLUSTER - 2) * SPC, root)

    # ---- Write files ----
    next_cluster = ROOT_CLUSTER + len(files)
    for name, content in files:
        name_u = name.upper().split('.')
        base, ext = name_u[0], (name_u[1] if len(name_u) > 1 else '')
        content_b = content if isinstance(content, (bytes, bytearray)) \
                    else content.encode('ascii')
        size = len(content_b)
        nclusters = (size + SECTOR - 1) // SECTOR
        start_cluster = next_cluster
        next_cluster += nclusters

        # directory entry
        entry = make_entry(base, ext, 0x20, start_cluster, size)
        # append to root directory
        # find an empty slot in the root dir (after volume label)
        root_off = (part_start + data_start + (ROOT_CLUSTER - 2) * SPC) * SECTOR
        # parse existing root dir to find free entry
        for i in range(32, SECTOR, 32):
            if data[root_off + i] == 0 or data[root_off + i] == 0xE5:
                data[root_off + i:root_off + i + 32] = entry
                break

        # file data + FAT chain
        for c in range(nclusters):
            cluster = start_cluster + c
            sector = data_start + (cluster - 2) * SPC
            chunk = content_b[c * SECTOR:(c + 1) * SECTOR]
            wsect(sector, chunk.ljust(SECTOR, b'\x00'))
            # FAT entry: EOC for last cluster, else next cluster
            if c == nclusters - 1:
                fatval = 0x0FFFFFFF
            else:
                fatval = cluster + 1
            off = (part_start + RESERVED) * SECTOR + cluster * 4
            struct.pack_into('<I', data, off, fatval)
            off2 = (part_start + RESERVED + fat_size) * SECTOR + cluster * 4
            struct.pack_into('<I', data, off2, fatval)

    with open(path, 'wb') as f:
        f.write(data)
    print(f"FAT32: {total_sectors} sectors, {fat_size}-sector FAT, "
          f"{len(files)} files at cluster {ROOT_CLUSTER + len(files)}")
    for name, _ in files:
        print(f"  + {name}")


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("usage: mkfat32.py <image> [--files name=path ...]")
        sys.exit(1)
    img = sys.argv[1]
    files = []
    args = sys.argv[2:]
    if args and args[0] == '--files':
        for spec in args[1:]:
            name, path = spec.split('=')
            with open(path, 'rb') as f:
                files.append((name, f.read()))
    else:
        # Default demo files.
        files = [
            ('README.TXT', b'X86ASMOS FAT32 filesystem.\r\nHello from the disk!\r\n'),
            ('INDEX.HTM', b'<html><body><h1>X86ASMOS</h1><p>served over HTTP</p></body></html>\r\n'),
            ('HELLO.JIT', b'++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.'),
        ]
    format_image(img, 2048, files)
