#!/usr/bin/env bash
# Shared public-source checks for Forgejo CI and tagged/manual ROM builds.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091  # versions.env contains only source/toolchain pins
source "$ROOT/versions.env"
[[ -f "$ROOT/src/CrabEFI/Cargo.toml" ]] || {
    echo "Run './build.sh payload' before the CrabEFI tests." >&2
    exit 1
}
python3 -I "$ROOT/tools/test_verify_auth_chain.py"
cd "$ROOT/src/CrabEFI"
cargo "+$CRABEFI_TOOLCHAIN" test --locked -p crabefi-varstore-gen -p crabefi-pkcs7
cargo "+$CRABEFI_TOOLCHAIN" test --locked --manifest-path xtask/Cargo.toml
cargo "+$CRABEFI_TOOLCHAIN" test --locked -p crabefi-core --lib --features full,enforce-secure-boot
# Owns the process-global trust caches, so run this ignored regression alone.
cargo "+$CRABEFI_TOOLCHAIN" test --locked -p crabefi-core --lib --features full,enforce-secure-boot \
    recheck_image_revocation -- --ignored --test-threads=1
cd crabefi-runtime-image
cargo "+$CRABEFI_TOOLCHAIN" test --locked --features secure-boot
