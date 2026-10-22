#!/usr/bin/env bash
# QEMU regression test for the locked CrabEFI payload in out/crabefi.elf.
#
# Uses CrabEFI's checked-in QEMU q35 coreboot image, renames its SMMSTORE
# FMAP area to RO_UEFI_VARS and writes out/varstore.bin there, exactly as the
# V1610 ROM carries it. Then boots secureblue's real, signed systemd-boot +
# UKI (+ one signed addon) from an NVMe ESP and checks:
#
#   good       signed chain verifies, kernel gets ExitBootServices
#   tampered   one flipped bit in the UKI's .linux -> SECURITY VIOLATION
#   swapped    a store that is not the one compiled in -> firmware halts
#   erased     no store at all -> firmware halts
#
# usage: tools/qemu-test.sh <systemd-bootx64.efi> <uki.efi> <addon.efi>
#   (take them from ghcr.io/secureblue/systemd-boot, the :uki image's
#    /boot/EFI/Linux and ghcr.io/secureblue/uki-addons)
# needs: qemu-system-x86_64 cbfstool mtools mkfs.vfat sgdisk zstd python3
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/out"
WORK="$OUT/qemu-test"
SDBOOT="${1:?systemd-bootx64.efi}" UKI="${2:?uki.efi}" ADDON="${3:?addon.efi}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-600}"   # TCG without KVM needs a few minutes for a 130 MB UKI
FAIL_TIMEOUT="${FAIL_TIMEOUT:-120}"

for f in "$OUT/crabefi.elf" "$OUT/varstore.bin" "$ROOT/src/CrabEFI/firmware/coreboot-qemu-q35.rom.zst"; do
    [ -s "$f" ] || { echo "missing $f: run './build.sh payload' first" >&2; exit 1; }
done
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

# --- ROMs --------------------------------------------------------------------
zstd -qdc "$ROOT/src/CrabEFI/firmware/coreboot-qemu-q35.rom.zst" > q35.rom
python3 -I - q35.rom base.rom <<'PY'
import sys
rom = bytearray(open(sys.argv[1], "rb").read())
at = rom.find(b"__FMAP__")
n = int.from_bytes(rom[at + 54:at + 56], "little")
for i in range(n):
    a = at + 56 + i * 42
    if bytes(rom[a + 8:a + 40]).rstrip(b"\0") == b"SMMSTORE":
        rom[a + 8:a + 40] = b"RO_UEFI_VARS".ljust(32, b"\0")
        break
else:
    sys.exit("q35 image has no SMMSTORE area")
open(sys.argv[2], "wb").write(rom)
PY
python3 -I -c '
import sys; d = bytearray(open(sys.argv[1], "rb").read()); d[-1] ^= 0xff
open(sys.argv[2], "wb").write(d)' "$OUT/varstore.bin" swapped.bin
for rom in good swapped erased; do
    cp base.rom "$rom.rom"
    case "$rom" in
        good)    cbfstool "$rom.rom" write -r RO_UEFI_VARS -f "$OUT/varstore.bin" ;;
        swapped) cbfstool "$rom.rom" write -r RO_UEFI_VARS -f swapped.bin ;;
    esac
    cbfstool "$rom.rom" add-payload -f "$OUT/crabefi.elf" -n fallback/payload -c lzma
done

# --- disks -------------------------------------------------------------------
python3 -I -c '
import sys, struct
d = bytearray(open(sys.argv[1], "rb").read())
pe = struct.unpack_from("<I", d, 0x3c)[0]
n, opt = struct.unpack_from("<H", d, pe + 6)[0], struct.unpack_from("<H", d, pe + 20)[0]
for i in range(n):
    e = pe + 24 + opt + i * 40
    if d[e:e + 8].rstrip(b"\0") == b".linux":
        d[struct.unpack_from("<I", d, e + 20)[0] + 0x2000] ^= 1
        break
open(sys.argv[2], "wb").write(d)' "$UKI" uki-tampered.efi

mkdisk() {  # <image> <uki>
    local esp_mb=$(( $(stat -c %s "$2") / 1048576 + 64 ))
    truncate -s $((esp_mb + 2))M "$1"
    sgdisk -o -n 1:2048:+${esp_mb}M -t 1:ef00 "$1" >/dev/null
    rm -f esp.fat; mkfs.vfat -F 32 -C esp.fat $((esp_mb * 1024)) >/dev/null
    mmd -i esp.fat ::/EFI ::/EFI/BOOT ::/EFI/Linux ::/loader ::/EFI/Linux/uki.efi.extra.d
    mcopy -i esp.fat "$SDBOOT" ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i esp.fat "$2" ::/EFI/Linux/uki.efi
    mcopy -i esp.fat "$ADDON" ::/EFI/Linux/uki.efi.extra.d/
    printf 'timeout 0\n' > loader.conf; mcopy -i esp.fat loader.conf ::/loader/loader.conf
    dd if=esp.fat of="$1" bs=1M seek=1 conv=notrunc status=none
}
mkdisk good.img "$UKI"
mkdisk tampered.img uki-tampered.efi

# --- runs --------------------------------------------------------------------
run() {  # <rom> <disk> <log> <seconds>
    timeout "$4" qemu-system-x86_64 -machine q35 -m 2G -smp 1 -cpu max \
        -nographic -no-reboot -monitor none -display none \
        -drive if=pflash,format=raw,file="$1",snapshot=on \
        -drive file="$2",if=none,id=nvm,format=raw,snapshot=on \
        -device nvme,serial=crabefi,drive=nvm \
        -serial file:"$3" >/dev/null 2>&1 || true
}
run good.rom     good.img     good.log     "$BOOT_TIMEOUT" &
run good.rom     tampered.img tampered.log "$BOOT_TIMEOUT" &
run swapped.rom  good.img     swapped.log  "$FAIL_TIMEOUT" &
run erased.rom   good.img     erased.log   "$FAIL_TIMEOUT" &
wait

fail=0
expect() {  # <log> <regex> <what>
    if grep -aEq "$2" "$1"; then echo "PASS  $3"; else echo "FAIL  $3 (see $WORK/$1)"; fail=1; fi
}
reject() {  # <log> <regex> <what>
    if grep -aEq "$2" "$1"; then echo "FAIL  $3 (see $WORK/$1)"; fail=1; else echo "PASS  $3"; fi
}
expect good.log     'locked policy satisfied'                 "good: keys loaded, Secure Boot enforcing"
expect good.log     'ExitBootServices SUCCESS'                "good: signed systemd-boot -> UKI reached the kernel"
reject good.log     'verification FAILED'                     "good: nothing rejected"
expect tampered.log 'verification FAILED - image not authorized' "tampered: modified UKI rejected"
reject tampered.log 'ExitBootServices SUCCESS'                "tampered: no kernel started"
expect swapped.log  'contents do not match the store'         "swapped: foreign store detected"
expect swapped.log  'refusing to boot'                        "swapped: firmware halts"
expect erased.log   'refusing to boot'                        "erased: firmware halts"
reject erased.log   'LoadImage'                               "erased: nothing loaded"
exit "$fail"
