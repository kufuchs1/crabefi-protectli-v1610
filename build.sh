#!/usr/bin/env bash
# Protectli V1610: coreboot + patched, locked CrabEFI. Never flashes hardware.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/out"
# shellcheck disable=SC1091  # source and toolchain configuration
source "$ROOT/versions.env"
JOBS="${JOBS:-$(nproc)}"
CRABEFI_KEYS="$SRC/secureblue-keys"  # filled by prepare_keys
CRABEFI_FMD="$ROOT/crabefi/v1610.fmd"
CRABEFI_PAYLOAD_FEATURES="bundled-runtime-image,locked-ro-store"
CRABEFI_OBJ="build-crabefi"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

resolve_sha() {  # <repo-url> <branch>; require the current remote tip
    local repo="$1" ref="$2" line
    if ! line="$(git ls-remote --exit-code "$repo" "refs/heads/$ref")" || [ -z "$line" ]; then
        die "cannot resolve current $repo branch '$ref'; refusing a cached/offline coreboot build"
    fi
    printf '%s\n' "${line%%[[:space:]]*}"
}

ensure_repo() {  # <repo-url> <local-dir> <sha>
    local repo="$1" dir="$2" sha="$3"
    if [ ! -d "$dir" ]; then
        log "cloning $repo"
        git clone "$repo" "$dir"
    fi
    git -C "$dir" remote set-url origin "$repo"
    # a shallow tree (left by './build.sh configs') can't check out arbitrary shas
    if [ -f "$dir/.git/shallow" ]; then
        log "unshallowing $dir"
        git -C "$dir" fetch --quiet --unshallow origin
    fi
    git -C "$dir" rev-parse -q --verify "$sha^{commit}" >/dev/null 2>&1 \
        || git -C "$dir" fetch --quiet origin
    git -C "$dir" rev-parse -q --verify "$sha^{commit}" >/dev/null 2>&1 \
        || die "commit $sha not found in $dir after fetch"
    git -C "$dir" checkout --quiet --detach "$sha"
}

check_crabefi_deps() {
    local missing=() t
    for t in git python3 openssl rustup sha256sum; do
        command -v "$t" >/dev/null || missing+=("$t")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing for the CrabEFI ROM: ${missing[*]}"
}

BLOBS=(descriptor.bin me.bin fspm.bin fsps.bin)

download_blobs() {  # <dir>; current blobs from the private repo
    [ -n "${BLOB_TOKEN:-}" ] || { echo "BLOB_TOKEN not set" >&2; return 1; }
    # The header comes from stdin (printf is a builtin) so the token never
    # appears in curl's argv, which other processes on the runner can read.
    printf 'Authorization: token %s\n' "$BLOB_TOKEN" \
        | curl -sSf --proto '=https' --retry 3 -H @- "$BLOBS_ARCHIVE_URL" \
        | tar xz -C "$1" --strip-components=4 coreboot-blobs/mainboard/protectli/V1610 \
        || return 1
    local f
    for f in "${BLOBS[@]}"; do
        [ -s "$1/$f" ] || { echo "archive lacks $f" >&2; return 1; }
    done
}

fetch_blobs() {
    local tmp
    tmp="$(mktemp -d)"
    download_blobs "$tmp" || { rm -rf "$tmp"; die "blob download from $BLOBS_ARCHIVE_URL failed"; }
    rm -rf "$ROOT/blobs"
    mkdir -p "$ROOT/blobs"
    cp "${BLOBS[@]/#/$tmp/}" "$ROOT/blobs/"
    rm -rf "$tmp"
    printf '%s\n' "$BLOBS_ARCHIVE_URL" > "$ROOT/blobs/SOURCE"
    sha256sum "${BLOBS[@]/#/$ROOT/blobs/}"
}

stage_release() {
    local rom
    rom="$(readlink "$OUT/coreboot-crabefi.rom")" \
        || die "out/coreboot-crabefi.rom symlink missing: run './build.sh crabefi-rom' first"
    # Verify before removing a previous staging directory.
    (cd "$OUT" && sha256sum --quiet -c checksums-crabefi.txt) \
        || die "CrabEFI output checksums failed"
    rm -rf "$ROOT/release"
    mkdir -p "$ROOT/release"
    cp "$OUT/$rom" "$OUT/crabefi.elf" "$OUT/varstore.bin" \
        "$OUT/coreboot-crabefi.config" "$OUT/cbfs-crabefi.txt" \
        "$OUT/crabefi-buildinfo.txt" "$OUT/checksums-crabefi.txt" "$ROOT/release/"
    (cd "$ROOT/release" && sha256sum --quiet -c checksums-crabefi.txt)
}

patch_coreboot_march() {  # $1 = coreboot dir
    local xc="$1/util/xcompile/xcompile"
    [ -f "$xc" ] || die "xcompile not found at $xc"
    sed -i 's/-march=i686/-march=tremont/' "$xc"
    grep -q -- '-march=tremont' "$xc" \
        || die "xcompile patch failed: -march=tremont not present after sed (upstream changed the baseline?)"
    rm -f "$1/build/xcompile" "$1/$CRABEFI_OBJ/xcompile"
}

prepare_coreboot_tree() {
    local sha; sha="$(resolve_sha "$COREBOOT_REPO" "$COREBOOT_REF")"
    # drop our local xcompile edit before checkout: a COREBOOT_REF bump with a
    # dirty tracked file would make 'git checkout --detach' refuse to switch
    if [ -d "$SRC/coreboot" ]; then
        git -C "$SRC/coreboot" checkout --quiet -- util/xcompile/xcompile 2>/dev/null || true
    fi
    ensure_repo "$COREBOOT_REPO" "$SRC/coreboot" "$sha"
    log "coreboot @ $sha; submodules (fsp, blobs, vboot...)"
    git -C "$SRC/coreboot" submodule update --init --checkout --quiet
    log "patching coreboot toolchain flags: -march=i686 -> -march=tremont"
    patch_coreboot_march "$SRC/coreboot"

    if [ -d "$ROOT/blobs" ]; then
        log "overlaying blobs/ into coreboot tree"
        mkdir -p "$SRC/coreboot/3rdparty/coreboot-blobs/mainboard/protectli/V1610"
        cp -v "$ROOT/blobs/"*.bin "$SRC/coreboot/3rdparty/coreboot-blobs/mainboard/protectli/V1610/"
    fi

    local cbdir="$SRC/coreboot"

    # Prefer an external crossgcc (XGCCPATH, e.g. the coreboot-sdk image);
    # otherwise build it in-tree once (~25 min) and reuse it from there.
    if [ -n "${XGCCPATH:-}" ]; then
        # coreboot convention: XGCCPATH is the bin dir, e.g. /opt/xgcc/bin/
        [ -x "${XGCCPATH%/}/i386-elf-gcc" ] \
            || die "XGCCPATH=$XGCCPATH set but no i386-elf-gcc there: expected the bin dir, e.g. /opt/xgcc/bin/"
        log "using external crossgcc from XGCCPATH=$XGCCPATH"
    elif [ ! -x "$cbdir/util/crossgcc/xgcc/bin/i386-elf-gcc" ]; then
        log "building coreboot crossgcc toolchain (one-time, slow)"
        make -C "$cbdir" crossgcc-i386 CPUS="$JOBS" \
            || die "crossgcc toolchain build failed"
    fi
}

xgcc_bin() {  # <tool> [args]: the crossgcc tool coreboot builds with
    local dir="${XGCCPATH:-$SRC/coreboot/util/crossgcc/xgcc/bin}"
    local tool="$1"; shift
    "${dir%/}/$tool" "$@"
}

crabefi_cargo() {  # cargo with CRABEFI_TOOLCHAIN, run inside the CrabEFI tree
    ( cd "$SRC/CrabEFI" && cargo "+$CRABEFI_TOOLCHAIN" "$@" )
}

fmd_area_size() {  # <fmd> <area>
    local size
    size="$(sed -n "s/^[[:space:]]*$2@[^ ]* \([0-9a-fA-Fx]*\).*/\1/p" "$1" | head -1)"
    [ -n "$size" ] || die "no $2 area in $1"
    printf '%d\n' "$size"
}

ensure_crabefi() {
    # drop the previously applied patch series before switching commits
    if [ -d "$SRC/CrabEFI/.git" ]; then
        git -C "$SRC/CrabEFI" reset --quiet --hard
    fi
    ensure_repo "$CRABEFI_REPO" "$SRC/CrabEFI" "$CRABEFI_REF"
    # pristine pinned tree, then our patch series on top (idempotent)
    git -C "$SRC/CrabEFI" reset --quiet --hard "$CRABEFI_REF"
    git -C "$SRC/CrabEFI" clean --quiet -fdx -e target/
    local patch
    for patch in "$ROOT"/crabefi/patches/*.patch; do
        git -C "$SRC/CrabEFI" apply --index "$patch" \
            || die "CrabEFI patch $(basename "$patch") does not apply to $CRABEFI_REF"
    done
    # updates to the current nightly; adds rust-src/the target if missing
    rustup toolchain install "$CRABEFI_TOOLCHAIN" --profile minimal \
        --component rust-src --target x86_64-unknown-none >/dev/null \
        || die "cannot install $CRABEFI_TOOLCHAIN"
}

cert_fingerprint() {  # <pem>: SHA-256 of the DER certificate
    openssl x509 -in "$1" -outform DER | sha256sum | cut -d' ' -f1
}

# PK/KEK/db exactly as secureblue's :uki image ships them in
# /usr/share/secureblue/uki/keys (uki/keys/*/*.auth and *.der).
download_secureblue_keys() {  # <dir>
    local line sha k ext
    line="$(git ls-remote --exit-code "$SECUREBLUE_REPO" "refs/heads/$SECUREBLUE_REF")" || return 1
    sha="${line%%[[:space:]]*}"
    for k in PK KEK db; do
        for ext in auth der; do
            curl -sSf --retry 3 -o "$1/$k.$ext" "$SECUREBLUE_RAW/$sha/uki/keys/$k/$k.$ext" || return 1
        done
        openssl x509 -inform DER -in "$1/$k.der" -out "$1/$k.pem" || return 1
    done
    printf '%s@%s\n' "$SECUREBLUE_REPO" "$sha" > "$1/SOURCE"
}

prepare_keys() {
    local tmp
    tmp="$(mktemp -d)"
    download_secureblue_keys "$tmp" \
        || { rm -rf "$tmp"; die "cannot fetch secureblue's uki keys from $SECUREBLUE_REPO ($SECUREBLUE_REF)"; }
    log "Secure Boot keys from $(cat "$tmp/SOURCE")"
    python3 -I "$ROOT/tools/verify-auth-chain.py" "$tmp" \
        || { rm -rf "$tmp"; die "secureblue PK/KEK/db do not form one signed PK->KEK->db hierarchy"; }
    # The chain check proves KEK and db were signed by the fetched PK; only
    # this pin proves the PK is secureblue's and not one served in its place.
    local pk; pk="$(cert_fingerprint "$tmp/PK.pem")"
    [ "$pk" = "$SECUREBLUE_PK_SHA256" ] \
        || { rm -rf "$tmp"; die "secureblue PK fingerprint $pk does not match SECUREBLUE_PK_SHA256 in versions.env"; }
    rm -rf "$CRABEFI_KEYS"
    mkdir -p "$(dirname "$CRABEFI_KEYS")"
    mv "$tmp" "$CRABEFI_KEYS"
}

build_crabefi() {
    prepare_keys

    # Keep upstream's relocation/code-model/software-SHA compiler settings.
    local flag_var
    for flag_var in RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_TARGET_X86_64_UNKNOWN_NONE_RUSTFLAGS CARGO_BUILD_RUSTFLAGS; do
        [ -z "${!flag_var:-}" ] || die "unset $flag_var to preserve the checked-in firmware compiler settings"
    done
    ensure_crabefi
    # firmware-side key-write timestamps and reproducible builds key off this
    local epoch; epoch="$(git -C "$SRC/CrabEFI" log -1 --format=%ct "$CRABEFI_REF")"

    log "building crabefi-varstore-gen ($CRABEFI_TOOLCHAIN)"
    crabefi_cargo build --release --locked -p crabefi-varstore-gen \
        || die "crabefi-varstore-gen build failed"

    local size; size="$(fmd_area_size "$CRABEFI_FMD" RO_UEFI_VARS)"
    log "generating read-only variable store ($size bytes)"
    "$SRC/CrabEFI/target/release/crabefi-varstore-gen" --size "$size" \
        --pk "$CRABEFI_KEYS/PK.auth" --kek "$CRABEFI_KEYS/KEK.auth" --db "$CRABEFI_KEYS/db.auth" \
        --output "$OUT/varstore.bin" \
        || die "variable store generation failed"
    local store_sha; store_sha="$(sha256sum "$OUT/varstore.bin" | cut -d' ' -f1)"

    log "building CrabEFI payload [$CRABEFI_PAYLOAD_FEATURES] bound to store $store_sha"
    SOURCE_DATE_EPOCH="$epoch" CRABEFI_RO_VARSTORE_SHA256="$store_sha" \
        crabefi_cargo build --profile firmware --locked -p crabefi-coreboot \
            --target x86_64-unknown-none \
            -Zbuild-std=core,alloc -Zbuild-std-features=compiler-builtins-mem \
            --no-default-features --features "$CRABEFI_PAYLOAD_FEATURES" \
        || die "CrabEFI payload build failed"
    install -m 0644 "$SRC/CrabEFI/target/x86_64-unknown-none/firmware/crabefi" "$OUT/crabefi.elf"
    # the locked payload must not contain the SPI flash writer
    local deps
    deps="$(crabefi_cargo tree --locked -p crabefi-coreboot --target x86_64-unknown-none \
            -e normal --prefix none --no-default-features --features "$CRABEFI_PAYLOAD_FEATURES")" \
        || die "cargo tree failed"
    case "$deps" in
        *rflasher*) die "locked payload pulls in the SPI flash driver" ;;
    esac
}

check_crabefi_coreboot_cfg() {  # <coreboot .config>
    local want
    for want in \
        "CONFIG_BOARD_PROTECTLI_V1610=y" \
        "CONFIG_PAYLOAD_ELF=y" \
        "CONFIG_COMPRESSED_PAYLOAD_LZMA=y" \
        "CONFIG_PAYLOAD_FILE=\"$OUT/crabefi.elf\"" \
        "CONFIG_FMDFILE=\"$CRABEFI_FMD\"" \
        "CONFIG_BOOTMEDIA_LOCK_CONTROLLER=y" \
        "CONFIG_BOOTMEDIA_LOCK_WHOLE_RO=y" \
        "CONFIG_CBFS_VERIFICATION=y" \
        "CONFIG_CBFS_HASH_SHA512=y" \
        "CONFIG_COREBOOT_ROMSIZE_KB=16384" \
        "CONFIG_LOCK_MANAGEMENT_ENGINE=y" \
        "CONFIG_PCI_SET_BUS_MASTER_PCI_BRIDGES=y" \
        "CONFIG_RUN_FSP_GOP=y" \
        "CONFIG_GENERIC_LINEAR_FRAMEBUFFER=y" \
        "CONFIG_INTEL_GMA_ADD_VBT=y" \
        "CONFIG_INTEL_GMA_VBT_FILE=\"src/mainboard/\$(MAINBOARDDIR)/data.vbt\"" \
        "CONFIG_INTEL_GMA_ACPI=y"; do
        grep -qxF "$want" "$1" || die "CrabEFI coreboot config lacks $want"
    done
    local unwanted
    # Bridges need bus mastering to forward an NVMe's DMA (CrabEFI enables it
    # only on the endpoint); endpoints stay off until CrabEFI drives them.
    for unwanted in UNLOCK_FLASH_REGIONS CBFS_ALLOW_UNVERIFIED_DECOMPRESSION PCI_ALLOW_BUS_MASTER_ANY_DEVICE \
            NO_GFX_INIT ALWAYS_ALLOW_ABOVE_4G_ALLOCATION; do
        ! grep -q "^CONFIG_$unwanted=y" "$1" || die "CONFIG_$unwanted must stay off"
    done
    ! grep -q '^CONFIG_SMMSTORE=y' "$1" || die "SMMSTORE must stay off: the variable store is read-only"
    ! grep -q '^CONFIG_PAYLOAD_LINUX=y' "$1" || die "unexpected Linux payload selected"
}

build_coreboot_crabefi() {
    if [ ! -s "$OUT/crabefi.elf" ] || [ ! -s "$OUT/varstore.bin" ]; then
        die "no crabefi.elf/varstore.bin: run './build.sh payload' first"
    fi
    prepare_coreboot_tree
    local cbdir="$SRC/coreboot"
    mkdir -p "$cbdir/$CRABEFI_OBJ"
    crabefi_coreboot_config "$cbdir/$CRABEFI_OBJ/.config"
    make -C "$cbdir" obj="$CRABEFI_OBJ" DOTCONFIG="$CRABEFI_OBJ/.config" olddefconfig
    check_crabefi_coreboot_cfg "$cbdir/$CRABEFI_OBJ/.config"
    report_config_drift "$cbdir/$CRABEFI_OBJ/.config"

    log "building coreboot ROM [crabefi] (-j$JOBS)"
    rm -f "$cbdir/$CRABEFI_OBJ/coreboot.rom" "$cbdir/$CRABEFI_OBJ/coreboot.pre"
    make -C "$cbdir" obj="$CRABEFI_OBJ" DOTCONFIG="$CRABEFI_OBJ/.config" \
        -j"$JOBS" BUILD_TIMELESS=1 KERNELVERSION=V1610 \
        || die "coreboot build [crabefi] failed"
    local rom="$cbdir/$CRABEFI_OBJ/coreboot.rom" cbfstool="$cbdir/$CRABEFI_OBJ/cbfstool"
    [ -s "$rom" ] || die "coreboot did not produce $CRABEFI_OBJ/coreboot.rom"
    [ "$(stat -c %s "$rom")" = 16777216 ] || die "CrabEFI ROM is not exactly 16 MiB"
    [ -x "$cbfstool" ] || cbfstool="$(command -v cbfstool)" || die "no cbfstool"

    log "writing read-only variable store into RO_UEFI_VARS"
    "$cbfstool" "$rom" write -r RO_UEFI_VARS -f "$OUT/varstore.bin" \
        || die "could not write RO_UEFI_VARS"
    "$cbfstool" "$rom" read -r RO_UEFI_VARS -f "$OUT/.varstore.readback" \
        || die "could not read RO_UEFI_VARS back"
    cmp -s "$OUT/.varstore.readback" "$OUT/varstore.bin" \
        || die "RO_UEFI_VARS read-back differs from varstore.bin"
    rm -f "$OUT/.varstore.readback"
    "$cbfstool" "$rom" print -r COREBOOT > "$OUT/cbfs-crabefi.txt"
    grep -q '^fallback/payload ' "$OUT/cbfs-crabefi.txt" \
        || die "no fallback/payload in the CrabEFI ROM"
    grep -q '^vbt\.bin ' "$OUT/cbfs-crabefi.txt" \
        || die "no vbt.bin in the CrabEFI ROM"

    cp "$cbdir/$CRABEFI_OBJ/.config" "$OUT/coreboot-crabefi.config"
    local tag; tag="$(date +%Y%m%d)-$(git -C "$cbdir" rev-parse --short HEAD)"
    cp "$rom" "$OUT/coreboot-$tag-crabefi.rom"
    ln -sf "coreboot-$tag-crabefi.rom" "$OUT/coreboot-crabefi.rom"
}

check_crabefi_rom_deps() {
    check_crabefi_deps
    local missing=() t f
    for t in git make gcc flex bison cmp stat; do
        command -v "$t" >/dev/null || missing+=("$t")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing for the coreboot build: ${missing[*]}"
    for f in "${BLOBS[@]}"; do
        [ -s "$ROOT/blobs/$f" ] \
            || die "missing blobs/$f: run './build.sh fetch-blobs' (needs BLOB_TOKEN) or copy the board blobs into blobs/"
    done
}

write_crabefi_buildinfo() {
    {
        printf 'crabefi_upstream=%s\ncrabefi_ref=%s\n' "$CRABEFI_REPO" "$CRABEFI_REF"
        printf 'crabefi_patched_tree=%s\n' "$(git -C "$SRC/CrabEFI" write-tree)"
        printf 'coreboot_commit=%s\n' "$(git -C "$SRC/coreboot" rev-parse HEAD)"
        printf 'rust_toolchain=%s\nfeatures=%s\n' "$CRABEFI_TOOLCHAIN" "$CRABEFI_PAYLOAD_FEATURES"
        printf 'coreboot_sdk_image=%s\n' "${COREBOOT_SDK_IMAGE:-not-used}"
        printf 'rustc=%s\n' "$(rustc "+$CRABEFI_TOOLCHAIN" --version)"
        printf 'i386_elf_gcc=%s\n' "$(xgcc_bin i386-elf-gcc --version | head -1)"
        printf '\nPatch SHA-256:\n'
        (cd "$ROOT" && sha256sum crabefi/patches/*.patch)
        printf 'blob_source=%s\n' "$(cat "$ROOT/blobs/SOURCE" 2>/dev/null || echo local)"
        printf 'secureblue_keys=%s\n' "$(cat "$CRABEFI_KEYS/SOURCE")"
        printf '\nSecure Boot certificate SHA-256 (DER):\n'
        local k
        for k in PK KEK db; do printf '%s  %s\n' "$(cert_fingerprint "$CRABEFI_KEYS/$k.pem")" "$k"; done
        printf '\nBoard blob SHA-256 (input identification, not signature verification):\n'
        (cd "$ROOT/blobs" && sha256sum "${BLOBS[@]}")
    } > "$OUT/crabefi-buildinfo.txt"
}

report_crabefi() {
    log "build complete"
    local rom
    rom="$(readlink "$OUT/coreboot-crabefi.rom")" \
        || die "out/coreboot-crabefi.rom symlink missing"
    write_crabefi_buildinfo
    local files=(crabefi.elf varstore.bin "$rom" coreboot-crabefi.config cbfs-crabefi.txt crabefi-buildinfo.txt)
    ls -lh "${files[@]/#/$OUT/}"
    ( cd "$OUT" && sha256sum "${files[@]}" > checksums-crabefi.txt )
    cat "$OUT/checksums-crabefi.txt"
    echo
    echo "Full 16 MB write with the external programmer:"
    echo "  flashprog -p ch347_spi -w $OUT/$rom"
}

# coreboot.txt is the complete board configuration; substitute only build paths.
crabefi_coreboot_config() {  # <output .config>
    python3 - "$ROOT/coreboot.txt" "$1" "$ROOT" "$OUT" <<'PY_CONFIG'
from pathlib import Path
import sys
source, output, root, out = sys.argv[1:]
Path(output).write_text(Path(source).read_text().replace('@ROOT@', root).replace('@OUT@', out))
PY_CONFIG
}

# coreboot main floats: show where olddefconfig moved away from coreboot.txt.
report_config_drift() {  # <resolved .config>
    local want; want="$(mktemp)"
    crabefi_coreboot_config "$want"
    if ! diff -u --label coreboot.txt --label resolved.config \
            <(grep -v '^#' "$want" | grep . | sort) <(grep -v '^#' "$1" | grep . | sort) \
            > "$OUT/coreboot-crabefi.config.drift"; then
        log "WARNING: olddefconfig changed coreboot.txt settings (refresh coreboot.txt after review):"
        cat "$OUT/coreboot-crabefi.config.drift"
    else
        rm -f "$OUT/coreboot-crabefi.config.drift"
    fi
    rm -f "$want"
}

# Validate current upstream coreboot without private board blobs or a crossgcc.
check_configs() {
    local t sha
    for t in git make gcc flex bison python3; do
        command -v "$t" >/dev/null || die "missing config-check dependency: $t"
    done
    sha="$(resolve_sha "$COREBOOT_REPO" "$COREBOOT_REF")"
    if [ ! -d "$SRC/coreboot" ]; then
        git init -q "$SRC/coreboot"
        git -C "$SRC/coreboot" remote add origin "$COREBOOT_REPO"
        git -C "$SRC/coreboot" fetch --quiet --depth 1 origin "$COREBOOT_REF"
        git -C "$SRC/coreboot" checkout --quiet --detach FETCH_HEAD
    else
        git -C "$SRC/coreboot" checkout --quiet -- util/xcompile/xcompile
        ensure_repo "$COREBOOT_REPO" "$SRC/coreboot" "$sha"
    fi
    mkdir -p "$SRC/coreboot/$CRABEFI_OBJ"
    crabefi_coreboot_config "$SRC/coreboot/$CRABEFI_OBJ/.config"
    make -C "$SRC/coreboot" obj="$CRABEFI_OBJ" DOTCONFIG="$CRABEFI_OBJ/.config" olddefconfig
    check_crabefi_coreboot_cfg "$SRC/coreboot/$CRABEFI_OBJ/.config"
    report_config_drift "$SRC/coreboot/$CRABEFI_OBJ/.config"
    # not coreboot-crabefi.config: that one is a checksummed ROM build output
    cp "$SRC/coreboot/$CRABEFI_OBJ/.config" "$OUT/coreboot-crabefi.configs-check.config"
    log "CrabEFI coreboot configuration verified"
}

usage() {
    echo "usage: $0 [rom|payload|configs|test|check|fetch-blobs|stage|clean]"
}

TARGET="${1:-rom}"
case "$TARGET" in
    -h|--help|help) usage; exit 0 ;;
    rom|crabefi-rom|payload|crabefi|configs|test|check|fetch-blobs|stage|clean) ;;
    *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer"
mkdir -p "$SRC" "$OUT"
case "$TARGET" in
    rom|crabefi-rom) check_crabefi_rom_deps; build_crabefi; build_coreboot_crabefi; report_crabefi ;;
    payload|crabefi) check_crabefi_deps; build_crabefi ;;
    configs) check_configs ;;
    test) "$ROOT/tools/test-crabefi.sh" ;;
    check) check_crabefi_deps; prepare_keys ;;
    fetch-blobs) fetch_blobs ;;
    stage) stage_release ;;
    clean) rm -rf "$OUT" "$ROOT/release" "$SRC/coreboot/$CRABEFI_OBJ" ;;
esac
