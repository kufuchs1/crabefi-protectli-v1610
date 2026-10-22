# Shrinking the CSE (ME) region

Reference for reducing the Intel CSE (ME) region on a HAP-disabled Jasper
Lake board and reallocating the freed space to the BIOS region.

**Platform.** Protectli V1610, Jasper Lake, 16 MB SPI, coreboot,
CSE 13.50.32.2215 (Consumer), HAP set (`PCHSTRP0` bit 16).

**Scope.** The security posture is established by the HAP bit; the CSE
halts during bring-up regardless of what else is in the region.
Everything below concerns flash geometry and the undocumented structures
that constrain it.

## 1. Target layout

| Region     | Range               | Size     |
| ---------- | ------------------- | -------- |
| Descriptor | `0x000000-0x000fff` | 4 KB     |
| ME         | `0x001000-0x17ffff` | 1532 KB  |
| BIOS       | `0x180000-0xffffff` | 14848 KB |

The authoritative flash layout is [`crabefi/v1610.fmd`](../crabefi/v1610.fmd).
It additionally reserves 64 KiB for `RO_UEFI_VARS` inside BIOS. The CBFS region is:

```text
COREBOOT size = (FLASH_SIZE - BIOS_BASE) - MRC_CACHE_SIZE - RO_UEFI_VARS_SIZE - FMAP_SIZE
              = (0x1000000 - 0x180000) - 0x10000 - 0x10000 - 0x1000
              = 0xE5F000
```

`CONFIG_CBFS_SIZE` is inactive with this custom FMD; use the FMD to change regions.

### Descriptor fields

```
FLREG0 (Descriptor)  0x000000-0x000fff
FLREG1 (BIOS)        0x180000-0xffffff
FLREG2 (ME)          0x001000-0x17ffff
FLMSTR1 (host)       0x00200300     rd: desc+BIOS   wr: BIOS
FLMSTR2 (ME)         0x00400500     rd: desc+ME     wr: ME
FLMSTR3, FLMSTR5     0x00000000
PCHSTRP0             0x00010000     HAP set
```

The master values are unchanged from stock. They are the correct profile
given `BOOTMEDIA_LOCK_CONTROLLER=y` + `BOOTMEDIA_LOCK_WHOLE_RO=y`:
FLOCKDN and the Protected Range registers re-arm each boot _after_ the
MRC cache write, so the BIOS region is read-only to the OS without
sacrificing memory-training persistence.

## 2. Region contents

**Retained** (required to reach the HAP halt, or required by the PMC):

| Partition      | Function                                                        |
| -------------- | --------------------------------------------------------------- |
| `RBEP`         | ROM boot extension; first image loaded by the CSE ROM           |
| `PMCP`         | PMC firmware; board does not power-sequence without it          |
| `FTPR`         | `rbe → bup` chain plus kernel, syslib, crypto, pm, vfs, storage |
| `OEMP`, `PCHC` | Key manifest, PCH configuration                                 |
| DataPartition  | `$FPT`: IMDP, HVMP, PSVN, IVBP, MFS, UTOK, FLOG, UEP            |

**Removed:**

| Partition | Size    | Rationale                                                            |
| --------- | ------- | -------------------------------------------------------------------- |
| `NFTP`    | ~1.3 MB | Runtime payloads (PAVP, DAL, ADSPA, iunitcse); never loaded post-HAP |
| `IUNP`    | ~40 KB  | IPU/camera firmware; no camera, `ipu` (PCI 04.0) disabled            |

**Reduced:** MFS emptied (file contents erased, page headers preserved),
shrunk 50 → 8 pages; UTOK, FLOG, UEP relocated to follow.

## 3. Structures constraining the region size

### 3.1 IFWI Layout Table at ME offset `0x10`

Read by the CSE ROM before any partition table. 14 LE dwords at
`0x10-0x48`, offsets relative to the ME region base.

| Offset          | Field                   | Factory value |
| --------------- | ----------------------- | ------------- |
| `+0x00`         | DataPartition offset    | `0x156000`    |
| `+0x04`         | DataPartition size      | `0x070000`    |
| `+0x08`         | Boot1 offset            | `0x001000`    |
| `+0x0c`         | Boot1 size              | `0x155000`    |
| `+0x10`         | Boot2 offset            | `0x1c6000`    |
| `+0x14`         | Boot2 size              | `0x15f000`    |
| `+0x18`-`+0x2c` | Boot3-Boot5 offset/size | `0`           |
| `+0x30`         | unidentified            | `0x22`        |
| `+0x34`         | unidentified            | `0`           |

**Constraint 1: every declared extent must lie within the region.**
Factory Boot2 ends at `0x325000`; any region smaller than that leaves it
dangling and the board does not POST. This is the primary reason a naive
region shrink fails.

**Constraint 2: Boot2 must be declared.** Observed:

| Boot2 state                                  | Result  |
| -------------------------------------------- | ------- |
| declared, in-region, content erased (`0xFF`) | boots   |
| declared, extent outside region              | no POST |
| absent (`offset = 0`, `size = 0`)            | no POST |

`0/0` is a valid encoding for Boot3-Boot5 but is not accepted for Boot2.
A shrunken layout therefore needs an erased Boot2 stub:

```
Boot1          0x001000..0x156000
DataPartition  0x156000..0x172000
Boot2          0x172000..0x17f000    declared, all 0xFF
```

Stub sizes of `0x9000` and `0xd000` were both verified working. The two
trailing dwords (`0x22`, `0`) were preserved verbatim; their meaning was
not determined.

### 3.2 `$FPT`, the data partition table

Located at region offset `0x156000`, not at region start.

**Entry offsets are relative to the FPT base**, not the region base.
Misreading this places the data partition ~1.3 MB lower than it is and
truncates MFS mid-partition.

**The header checksum covers the 32-byte header only.** Invariant:
`sum(header[0:0x20]) % 256 == 0`.

Derivation: the factory image sums to `0` over the header but to `147`
over header+entries. Since that image boots, the checksum cannot cover
the entry table. Entry offsets and sizes may therefore be rewritten
without recomputation; the checksum byte only needs attention if header
bytes change.

| Partition   | Factory (FPT-rel)    | Repacked (FPT-rel)   |
| ----------- | -------------------- | -------------------- |
| `IMDP`      | `0x000f80 + 0x00040` | unchanged            |
| `HVMP`      | `0x000fc0 + 0x0000c` | unchanged            |
| `PSVN`      | `0x001000 + 0x00200` | unchanged            |
| `IVBP`      | `0x002000 + 0x04000` | unchanged            |
| `MFS`       | `0x006000 + 0x64000` | `0x006000 + 0x10000` |
| `UTOK`      | `0x06a000 + 0x02000` | `0x016000 + 0x02000` |
| `FLOG`      | `0x06c000 + 0x02000` | `0x018000 + 0x02000` |
| `UEP`       | `0x06e000 + 0x02000` | `0x01a000 + 0x02000` |
| **DP size** | `0x70000`            | `0x1c000`            |

### 3.3 MFS page format

`0x2000`-byte pages, each prefixed by an 18-byte header.

| Offset | Size | Field                                        |
| ------ | ---- | -------------------------------------------- |
| `0x00` | 4    | magic `0xAA557887`                           |
| `0x04` | 4    | USN                                          |
| `0x08` | 4    | erase count                                  |
| `0x0c` | 2    | page index                                   |
| `0x0e` | 2    | first-chunk index (+`0x7a` per page)         |
| `0x10` | 2    | checksum (8-bit value; high byte always `0`) |

Factory occupancy: 46 of 50 pages already empty (header only, body
`0xFF`); pages 0, 4, 5, 48 held ~20 KB total. Page 49 has a zeroed
magic; that is the spare/erase-target page.

**The checksum is a function of the header only.** An affine GF(2)
model (the general form of any CRC, independent of polynomial, init, or
bit order) was fitted on the 46 empty pages (identical `0xFF` bodies)
and used to predict the four data pages, whose bodies differ:

| Page | Predicted | Actual |
| ---- | --------- | ------ |
| 0    | `0xb1`    | `0xb1` |
| 4    | `0x8b`    | `0x8b` |
| 5    | `0x65`    | `0x65` |
| 48   | `0x90`    | `0x90` |

Each held-out feature vector lies in the span of the training set, so the
prediction is unique across the entire solution space rather than an
artifact of one solution. Four independent 8-bit matches under a
body-dependent hypothesis would be 2^-32.

Consequence: **erasing page bodies while preserving headers preserves
every checksum.** Blanking whole pages invalidates all 50.

## 4. Pre-flash verification

Before flashing, check:

1. ME blob size ≤ declared ME region size
2. ROM contains that exact blob at the ME region base
3. FMAP `BIOS` area lies within the IFD BIOS region
4. Every IFWI Layout Table extent lies within the region
5. Every BPDT entry extent lies within the region

Checks 4 and 5 are the ones that matter for a region resize; both real
defects encountered in this work would have been caught by them before
flashing.

Manual cross-check when a build fails: diff the failing descriptor
against a known-good one. Only the region-boundary bytes (`0x44-0x45`,
`0x4a-0x4b`) should differ.

## 5. Behaviour notes

**Double reset on first boot after flashing.** Cold MRC cache → full
memory training → reset → normal boot. Verified by reading the flash
afterwards: the only modified bytes were 21,092 within `RW_MRC_CACHE`
(magic `MRCd`); the ME region was byte-identical to the flashed image.
The CSE performs no writes, so the emptied MFS persists and no flash wear
accrues.

**Unused BIOS-region gap.** coreboot anchors its FMAP at the top of
flash. If `CBFS_SIZE` is smaller than the region permits, the remainder
sits unused between the ME region and the FMAP `BIOS` area. Confirm the
configured value reached the build (`grep CBFS_SIZE build/config.h`) if
the gap is unexpected.

## 6. Not attempted

| Item                                                                  | Reason                                                                                                                                 |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Relocating the DataPartition to reclaim FTPR's ~192 KB tail padding   | DP discovery mechanism beyond the Layout Table entry not established; small gain                                                       |
| GPIO pad locking (`PADCFGLOCK`)                                       | JSL does not select `SOC_INTEL_COMMON_BLOCK_SMM_LOCK_GPIO_PADS`; requires porting, and the underlying controllers are already disabled |
| Removing SMM (`HAVE_SMI_HANDLER` is hard-selected by the JSL Kconfig) | Independent of this work; flash protection already carried by `INTEL_CHIPSET_LOCKDOWN` + PRR                                           |

The remaining region contents are the minimum for the CSE to reach its
HAP halt and for the PMC to sequence the board. Further reduction has a
no-POST failure mode and no security benefit, since the HAP bit already
prevents execution of everything removable.
