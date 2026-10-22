# Protectli V1610 CrabEFI firmware

A full 16 MiB coreboot ROM for the Protectli V1610 (Jasper Lake), with CrabEFI
and Secure Boot locked to the included secureblue keys:

```text
coreboot -> CrabEFI -> signed systemd-boot -> signed UKI -> secureblue
```

The serial console runs at 115200 baud. The HDMI port (DDI C) is initialized by
the FSP GOP driver with the board VBT (`data.vbt` in the coreboot board
directory), and CrabEFI exposes that framebuffer as the UEFI GOP. The repository
contains the coreboot board configuration, flash layout,
CrabEFI security/deployment patches, build tools and Forgejo workflows.

## Build

Install host dependencies on Debian/Ubuntu:

```sh
apt-get update
apt-get install --yes build-essential git curl ca-certificates python3 openssl \
  flex bison bc libssl-dev zlib1g-dev libncurses-dev m4 bzip2 xz-utils patch \
  cmake pkg-config util-linux
```

Install rustup through its official installation instructions. The builder
installs and updates the current Rust nightly on every build.
Set `XGCCPATH=/opt/xgcc/bin/` to use a coreboot SDK toolchain; otherwise the
builder creates coreboot's crossgcc toolchain once. `JOBS` controls parallelism.

Provide `descriptor.bin`, `me.bin`, `fspm.bin` and `fsps.bin` in the ignored
`blobs/` directory, or let `./build.sh fetch-blobs` fill it. That downloads the
current blobs from `https://git.fuchskurt.eu/kurtfuchs/coreboot-blobs` and
requires `BLOB_TOKEN` with read access to that repository; it fails if the
token is unset or the repository is unreachable. The source used is recorded as `blob_source` in
`crabefi-buildinfo.txt`.

```sh
./build.sh fetch-blobs
./build.sh                       # build the CrabEFI ROM
(cd out && sha256sum -c checksums-crabefi.txt)
./build.sh stage                 # verified release files in release/
```

The image is `out/coreboot-crabefi.rom`, a symlink to its dated filename.
Outputs also include the matching `crabefi.elf`, `varstore.bin`, resolved
`coreboot-crabefi.config`, `cbfs-crabefi.txt`, `crabefi-buildinfo.txt`, and
`checksums-crabefi.txt`. Build metadata records the source commits and patch/blob
hashes; checksums identify the outputs and do not replace your signatures.

Coreboot always uses the current remote `main` from
`https://codeberg.org/kurtfuchs/coreboot.git`. There is no fixed coreboot commit
or fallback to a stale offline checkout. The SDK tracks the newest
`docker.io/coreboot/coreboot-sdk:testing` image. CrabEFI uses an exact upstream
revision plus the ten checked-in patches; there is no maintained fork
requirement.

`coreboot.txt` is the complete CrabEFI board configuration, with only `@ROOT@`
and `@OUT@` build paths substituted. `crabefi/v1610.fmd` defines the flash regions.
The builder checks the board, payload, SHA-512 CBFS verification (no unverified
decompression), flash-lock, ME-region lock and no-unlocked-regions settings after
`olddefconfig`, requires a 16 MiB ROM and reads back the embedded store to compare
every byte. It also requires FSP GOP graphics init with a linear framebuffer, the
VBT in CBFS (`vbt.bin`, also used for the IGD OpRegion) and endpoint BARs below
4 GiB (no `ALWAYS_ALLOW_ABOVE_4G_ALLOCATION`), within CrabEFI's 64 GiB identity
map. coreboot sets bus mastering only on PCI bridges, which must forward
the NVMe controller's DMA; CrabEFI enables it on the devices it drives and
clears it again before handing off to the OS, except on the IGD, which keeps
scanning out the GOP framebuffer. Because coreboot `main` floats, any setting `olddefconfig` changed
relative to `coreboot.txt` is printed as a warning and kept in
`out/coreboot-crabefi.config.drift`; review it and refresh `coreboot.txt`.

## Checks

```sh
./build.sh check                 # dependencies, fetched keys and signed hierarchy
./build.sh configs               # current coreboot main + board/security invariants
                                 # (writes out/coreboot-crabefi.configs-check.config)
./build.sh payload               # patched locked ELF and store, without board blobs
./build.sh test                  # host security suites; run after payload
```

The shared test suite covers PK/KEK/db authorization, certificate constraints,
CMS and Authenticode validation, revocation, variable-store generation and the
runtime/host tools. `tools/qemu-test.sh <systemd-boot.efi> <uki.efi> <addon.efi>`
checks the real signed boot chain plus modified UKI, substituted store and
erased store rejection using CrabEFI's q35 reference firmware. It does not
replace a V1610 hardware test.

## Forgejo / Codeberg

The `.forgejo/workflows/` pipelines are:

- `ci.yml` runs shell/config checks and builds/tests the public patched payload
  on main pushes and pull requests, without private board blobs.
- `build.yml` builds the CrabEFI ROM on manual runs or tag pushes, runs the same
  security suites, verifies staging and retains manual artifacts or publishes a
  tag release. Nothing is flashed automatically.

Enable repository Actions and register a runner with the `VPS` label.
Set `container.force_pull: true` in the runner configuration to refresh the
floating SDK image on every run. Set the repository Actions secret `BLOB_TOKEN`
for the private board archive; without it, or when `git.fuchskurt.eu` is
unreachable, the build fails. Releases use Forgejo's automatic repository token. The retained
`GITHUB_TOKEN` and `GITHUB_PATH` identifiers are Forgejo compatibility names and
do not require a GitHub account or credential. Actions use explicit Forgejo URLs;
manual artifacts use its supported v3 protocol.

Artifacts and releases contain the board blobs inside the ROM and follow the
repository's access rules, so keep the repository private. Live Forgejo and physical-board validation require
the configured runner and private blobs; they were not run in this cloud.

## Secure Boot and flashing

PK/KEK/db are part of the ROM. Each build fetches the `.auth` and `.der` files
from secureblue's `uki/keys/` (the same files its `:uki` image ships in
`/usr/share/secureblue/uki/keys/`) at the current tip of the `live` branch,
recorded as `secureblue_keys` with the certificate fingerprints in
`crabefi-buildinfo.txt`. There is no local copy: if GitHub is unreachable, the
build fails. Their authenticated updates and certificate hierarchy are verified
before generating the 64 KiB store. The
payload contains its SHA-256, reads it through the memory-mapped flash window,
and refuses to boot with a foreign, corrupt or erased store. Secure Boot cannot
be disabled through variables or the menu. Writable SPI storage, capsule
updates, xHCI and TPM support are excluded from this payload variant.

Only binaries authorized by the included secureblue db boot. Microsoft-signed
shim/standard CoreOS installer media are not authorized. Prepare the secureblue
installation on the NVMe using another machine and select its Platform Key
installation option. The firmware already contains the keys; do not enroll a
second key hierarchy. Key rotations take effect with the next ROM build and
flash. There is currently no provisioned dbx or rollback counter.

The flash geometry differs from factory firmware. Use a full 16 MiB external
write and keep the original descriptor/ME pair for recovery. After reviewing
the image and board-specific flashing procedure:

```sh
flashprog -p ch347_spi -w out/coreboot-crabefi.rom
```

See [flash layout and CSE notes](docs/flash-layout.md). After boot, check
`mokutil --sb-state`, `bootctl status`, `efi-readvar -v PK`, and the coreboot log
for flash-lock and read-only-store initialization. CBFS checks and the store
hash assume trusted firmware; physical flash protection still needs verification
on the V1610.
