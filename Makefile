# X86ASMOS — Makefile (Linux/macOS; NASM + Python 3 + QEMU)
# On Windows use build.ps1 instead.

NASM   := nasm
PY     := python3
QEMU   := qemu-system-i386
BUILD  := build

all: $(BUILD)/x86asmos.img $(BUILD)/x86asmos.iso

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/boot.bin: src/boot/boot.asm | $(BUILD)
	$(NASM) -f bin -o $@ $<

$(BUILD)/kernel.bin: src/kernel/kernel.asm | $(BUILD)
	$(NASM) -f bin -o $@ $<

KERNEL_SECTORS_ACTUAL := $(shell python3 -c "import os;print((os.path.getsize('$(BUILD)/kernel.bin')+511)//512)")

$(BUILD)/stage2.bin: src/boot/stage2.asm $(BUILD)/kernel.bin | $(BUILD)
	$(NASM) -f bin -o $@ -DKERNEL_SECTORS=$(KERNEL_SECTORS_ACTUAL) $<

$(BUILD)/x86asmos.img: $(BUILD)/boot.bin $(BUILD)/stage2.bin $(BUILD)/kernel.bin
	$(PY) tools/mkimg.py $@ $(BUILD)/boot.bin $(BUILD)/stage2.bin $(BUILD)/kernel.bin
	$(PY) tools/mkfat32.py $@

$(BUILD)/x86asmos.iso: $(BUILD)/x86asmos.img
	$(PY) tools/mkiso.py $< $@

run: all
	$(QEMU) -m 128M -drive format=raw,file=$(BUILD)/x86asmos.img,if=ide \
	  -netdev user,id=n0,hostfwd=tcp::8080-:80 -device rtl8139,netdev=n0

run-serial: all
	$(QEMU) -m 128M -drive format=raw,file=$(BUILD)/x86asmos.img,if=ide \
	  -netdev user,id=n0,hostfwd=tcp::8080-:80 -device rtl8139,netdev=n0 \
	  -serial stdio -display none

clean:
	rm -rf $(BUILD)

.PHONY: all run run-serial clean
