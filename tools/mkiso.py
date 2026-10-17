#!/usr/bin/env python3
"""mkiso.py - build a bootable El Torito ISO from the disk image.

Uses floppy-emulation boot: the first 2880 sectors (1.44 MiB) of the raw disk
image become the El Torito boot image, so the BIOS emulates a 1.44 MiB floppy
and our CHS/LBA bootloader loads the kernel exactly as it does from a floppy.

Usage: python tools/mkiso.py build/x86asmos.img build/x86asmos.iso
"""

import struct
import sys

SECTOR = 2048  # ISO sector size (2 KiB)


def write_sector(f, lba, data):
    f.seek(lba * SECTOR)
    f.write(data.ljust(SECTOR, b'\x00'))


def both_endian(fmt, *vals):
    return struct.pack('<' + fmt, *vals) + struct.pack('>' + fmt, *vals)


def build_pvd():
    d = bytearray(SECTOR)
    d[0] = 1                            # type: primary volume descriptor
    d[1:6] = b'CD001'
    d[6] = 1                            # version
    d[8:40] = b'X86ASMOS '.ljust(40 - 8, b' ')
    d[40:72] = b'X86ASMOS CD '.ljust(32, b' ')
    d[81:89] = b'20260101'              # creation date
    d[121:125] = both_endian('H', 1)    # volume set size
    d[129:133] = both_endian('H', 1)    # volume sequence number
    d[133:137] = both_endian('H', SECTOR)  # logical block size
    d[157:161] = b'\x00' * 4            # (path table size 0, simplified)
    d[881:889] = b'X86ASMOS'            # (publisher, simplified)
    return d


def build_boot_record(catalog_lba):
    d = bytearray(SECTOR)
    d[0] = 0                            # type: boot record
    d[1:6] = b'CD001'
    d[6] = 1
    d[7:39] = b'EL TORITO SPECIFICATION'.ljust(32, b'\x00')
    d[71:75] = struct.pack('<I', catalog_lba)
    return d


def build_terminator():
    d = bytearray(SECTOR)
    d[0] = 255
    d[1:6] = b'CD001'
    d[6] = 1
    return d


def build_boot_catalog(boot_lba):
    d = bytearray(SECTOR)
    # Validation entry (32 bytes)
    d[0] = 0x01                         # header ID
    d[1] = 0x00                         # platform ID (x86)
    d[2:4] = b'\x00\x00'                # reserved
    d[4:28] = b'\x00' * 24              # id string
    d[28] = 0x55
    d[29] = 0xAA                        # key
    d[30] = 0x55                        # checksum word (55 AA)
    d[31] = 0xAA
    # Initial/default entry (32 bytes)
    e = 32
    d[e] = 0x88                         # bootable
    d[e + 1] = 0x01                     # media type: 1.44 MiB floppy
    d[e + 2] = 0x00
    d[e + 3] = 0x00                     # load segment 0x0000
    d[e + 4] = 0x00                     # system type
    d[e + 5] = 0x00                     # unused
    d[e + 6:e + 8] = struct.pack('<H', 1)  # sector count
    d[e + 8:e + 12] = struct.pack('<I', boot_lba)  # load RBA
    d[e + 12:e + 32] = b'\x00' * 20
    return d


def main(img_path, iso_path):
    with open(img_path, 'rb') as f:
        img = f.read()
    boot_sectors = 2880  # 1.44 MiB floppy image
    boot_bytes = img[:boot_sectors * 512].ljust(boot_sectors * 512, b'\x00')

    PVD_LBA = 16
    BOOT_RECORD_LBA = 17
    TERMINATOR_LBA = 18
    CATALOG_LBA = 19
    BOOT_LBA = 20

    with open(iso_path, 'wb') as f:
        # sectors 0-15 reserved
        write_sector(f, PVD_LBA, build_pvd())
        write_sector(f, BOOT_RECORD_LBA, build_boot_record(CATALOG_LBA))
        write_sector(f, TERMINATOR_LBA, build_terminator())
        write_sector(f, CATALOG_LBA, build_boot_catalog(BOOT_LBA))
        # boot image (floppy emulation)
        f.seek(BOOT_LBA * SECTOR)
        f.write(boot_bytes)
        # pad to a round size
        end = BOOT_LBA * SECTOR + len(boot_bytes)
        f.truncate(end)

    print(f"ISO: {iso_path} ({BOOT_LBA * SECTOR + len(boot_bytes)} bytes)")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("usage: mkiso.py <img> <iso>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
