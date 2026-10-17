# =============================================================================
# X86ASMOS - Build Script (Windows PowerShell)
# -----------------------------------------------------------------------------
# Usage:
#   .\build.ps1            - assemble + build disk image
#   .\build.ps1 -run       - build and boot in QEMU
#   .\build.ps1 -run serial - build and boot in QEMU with serial on stdio
#   .\build.ps1 -clean     - remove build artifacts
# =============================================================================

param(
    [switch]$Run,
    [switch]$Clean,
    [string]$Mode = ""
)

$ErrorActionPreference = "Stop"

$Root   = $PSScriptRoot
$Build  = Join-Path $Root "build"
$Src    = Join-Path $Root "src"

# --- Image layout constants (MUST match src/boot/stage2.asm) ---------------
$KernelLbaStart = 17
$KernelSectors  = 2032
$TotalSectors   = 32768          # 16 MiB disk image

# --- Locate NASM -----------------------------------------------------------
function Find-Nasm {
    $candidates = @(
        "C:\Users\MSI\AppData\Local\bin\NASM\nasm.exe",
        "C:\nasm\nasm-2.16.01\nasm.exe",
        "C:\Program Files\NASM\nasm.exe",
        "C:\Program Files (x86)\NASM\nasm.exe",
        "C:\NASM\nasm.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command nasm -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "NASM not found. Install it or update Find-Nasm in build.ps1."
}

# --- Locate QEMU -----------------------------------------------------------
function Find-Qemu {
    $candidates = @(
        "C:\Program Files\qemu\qemu-system-i386.exe",
        "C:\Program Files (x86)\qemu\qemu-system-i386.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command qemu-system-i386 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$Nasm = Find-Nasm
Write-Host "NASM: $Nasm"

if ($Clean) {
    if (Test-Path $Build) { Remove-Item -Recurse -Force $Build }
    Write-Host "Cleaned."
    exit 0
}

New-Item -ItemType Directory -Force -Path $Build | Out-Null

# --- Assemble the three stages --------------------------------------------
function Asm([string]$in, [string]$out, [string[]]$extra = @()) {
    & $Nasm -f bin -o (Join-Path $Build $out) @extra (Join-Path $Src $in)
    if ($LASTEXITCODE -ne 0) { throw "NASM failed on $in" }
}

Asm "boot\boot.asm"   "boot.bin"
Asm "kernel\kernel.asm" "kernel.bin"

# Compute the kernel size in sectors and feed it to the Stage 2 loader so it
# only loads the real image (not the padding).
$kernelSize = (Get-Item (Join-Path $Build "kernel.bin")).Length
if ($kernelSize -gt (512 * 1024)) {
    throw "kernel.bin ($kernelSize bytes) exceeds the 512 KiB low-memory staging limit"
}
$kernelSectors = [math]::Ceiling($kernelSize / 512.0)
Asm "boot\stage2.asm" "stage2.bin" @("-DKERNEL_SECTORS=$kernelSectors")

# --- Validate sizes --------------------------------------------------------
$bootSize   = (Get-Item (Join-Path $Build "boot.bin")).Length
$stage2Size = (Get-Item (Join-Path $Build "stage2.bin")).Length

if ($bootSize -ne 512)     { throw "boot.bin must be 512 bytes, got $bootSize" }
if ($stage2Size -gt 8192)  { throw "stage2.bin too large: $stage2Size bytes" }
if ($kernelSize -gt ($KernelSectors * 512)) {
    throw "kernel.bin ($kernelSize) exceeds reserved area ($($KernelSectors*512) bytes)"
}

Write-Host ("boot.bin   = {0} bytes" -f $bootSize)
Write-Host ("stage2.bin = {0} bytes" -f $stage2Size)
Write-Host ("kernel.bin = {0} bytes ({1} sectors)" -f $kernelSize, $kernelSectors)

# --- Build the disk image --------------------------------------------------
$imagePath = Join-Path $Build "x86asmos.img"
$fs = [System.IO.File]::Create($imagePath)

function Write-Bytes([int]$count) {
    if ($count -le 0) { return }
    $buf = New-Object byte[] $count
    $fs.Write($buf, 0, $buf.Length)
}

try {
    # Sector 0: boot sector (512 bytes with 0xAA55 signature)
    $b = [System.IO.File]::ReadAllBytes((Join-Path $Build "boot.bin"))
    $fs.Write($b, 0, $b.Length)

    # Sectors 1-16: stage 2 (8192 bytes, padded by NASM)
    $s = [System.IO.File]::ReadAllBytes((Join-Path $Build "stage2.bin"))
    $fs.Write($s, 0, $s.Length)

    # Sectors 17 .. 17+KERNEL_SECTORS-1: kernel (padded to full area)
    $k = [System.IO.File]::ReadAllBytes((Join-Path $Build "kernel.bin"))
    $fs.Write($k, 0, $k.Length)
    Write-Bytes (($KernelSectors * 512) - $k.Length)

    # Remainder of the 16 MiB image (future FAT32 partition space).
    $written = 512 + 8192 + ($KernelSectors * 512)
    Write-Bytes (($TotalSectors * 512) - $written)
}
finally {
    $fs.Close()
}

$imgSize = (Get-Item $imagePath).Length
Write-Host ("Image      = {0} bytes ({1} MiB)" -f $imgSize, ($imgSize / 1MB))

# --- Format the FAT32 partition (from LBA 2048) ---------------------------
$mkfat = Join-Path $Root "tools\mkfat32.py"
if (Test-Path $mkfat) {
    python $mkfat $imagePath
    if ($LASTEXITCODE -ne 0) { throw "mkfat32.py failed" }
}

# --- Build the bootable El Torito ISO -------------------------------------
$mkiso = Join-Path $Root "tools\mkiso.py"
$isoPath = Join-Path $Build "x86asmos.iso"
if (Test-Path $mkiso) {
    python $mkiso $imagePath $isoPath
    if ($LASTEXITCODE -ne 0) { throw "mkiso.py failed" }
}

# --- Run in QEMU -----------------------------------------------------------
if ($Run) {
    $qemu = Find-Qemu
    if (-not $qemu) { throw "QEMU not found. Run without -run, or install QEMU." }

    $args = @("-m","128M","-drive","format=raw,file=$imagePath,if=ide")
    if ($Mode -eq "serial") {
        $args += @("-serial","stdio","-display","none")
    } else {
        $args += @("-serial","file:$(Join-Path $Build 'serial.log')")
    }
    Write-Host "QEMU: $qemu"
    & $qemu @args
}
