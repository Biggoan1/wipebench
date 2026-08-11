# WipeBench

A bootable USB that **sanitises every drive in a machine, then reimages it** — built for the
a corporate surplus workflow. One stick handles a mixed fleet: Dell, Microsoft Surface and Panasonic
Toughbook, wiping NVMe and spinning media by different methods and injecting model-specific
drivers into the new Windows image.

This repository holds **the source and the instructions**. It deliberately does not hold the
build artefacts — see [What is not here](#what-is-not-here).

---

## How the stick is laid out

A built stick is GPT with three partitions:

| # | FS | Size | Label | Contents |
|---|----|------|-------|----------|
| 1 | FAT32 | 2 GB | `WINPE` | WinPE boot files, `DellCleaner.ps1`, `sources\boot.wim` |

> WinPE's own `startnet.cmd` and `Startup.ps1` live **inside `boot.wim`**, not as loose
> files, so they are not in this repository. Service them with
> `WipeBenchDrivers.ps1 -Action PEDriver` or by mounting the WIM with DISM.
| 2 | ext4 | 8 GB | *(raw)* | Debian 13 + GRUB. **The wipe engine lives here** |
| 3 | NTFS | rest | `WIPEBENCHNTFS` | `sources\install.wim`, `Drivers\`, `Evidence\` |

GRUB chainloads WinPE by the FAT32 **volume serial**, so a rebuild restores that serial rather
than letting Windows generate a fresh one — otherwise the boot entry stops resolving.

### What runs, in order

1. **GRUB** — `Auto-Wipe`, `Wipe only`, or `Manual mode` (takes no destructive action).
2. **`auto_wipe.sh`** — 10-second abort window, then BIOS password clear (Dell), then the wipe,
   then writes evidence to partition 3.
3. **`wipe_mixed.sh`** — NVMe via `nvme sanitize`, everything else via Active@ KillDisk.
4. **WinPE / `DellCleaner.ps1`** — applies `install.wim`, resolves this machine's driver pack and
   injects it with DISM.

---

## What is not here

| Excluded | Why | Where it belongs |
|---|---|---|
| `linux-part.img` (8 GB) | build artefact | `C:\WipeBenchImages\` |
| `install.wim`, `boot.wim` | build artefact | `C:\WipeBenchImages\payload\sources\`, `winpe\sources\` |
| `Drivers\` (~250 GB) | re-downloadable, see [Drivers](#drivers) | `C:\WipeBenchImages\payload\Drivers\` |
| Active@ KillDisk binaries **and its registration key** | **licensed to the customer — do not redistribute** | `/opt/lsoft/KillDisk/` inside partition 2 |
| `bios_clear.sh`, `bios_set.sh`, `bios_scripts/` | **contain the Dell BIOS admin password derivation** | `/opt/wipebench/` inside partition 2 — see [BIOS scripts](#bios-scripts) |
| `CustomJohn/` incl. `unattend.xml` | personal provisioning, contains credentials | `C:\WipeBenchImages\payload\CustomJohn\` |

> **Do not commit any of the above.** `.gitignore` blocks them, but an allow-list that permits
> `*.txt` once swallowed the KillDisk licence file — check `git diff --cached` before pushing.

### BIOS scripts

`bios_clear.sh` and `bios_set.sh` are **excluded from this repository** because they encode the
Dell BIOS admin password scheme. They are not optional — without them `auto_wipe.sh` skips the
BIOS password clear and logs a warning, and Dell machines with a set BIOS password will not
accept boot-order changes.

**Where they go:** `/opt/wipebench/bios_clear.sh`, `/opt/wipebench/bios_set.sh`, and
`/opt/wipebench/bios_scripts/` — inside partition 2 (the ext4 image), mode `755`, owned by root.
Obtain them from the secure store, then either place them in a mounted `linux-part.img` before
building, or mount the built stick's partition 2 and drop them in. `auto_wipe.sh` calls
`bios_clear.sh` only when it exists and the machine is a Dell, so a stick without them still
wipes and reimages correctly — it just leaves BIOS passwords alone.

---

## Building from nothing

### Prerequisites

- Windows 10/11 with **PowerShell 5.1** and an **elevated** session (raw disk writes)
- ~300 GB free for the image set and driver library
- A 512 GB USB NVMe enclosure for production sticks (a 120 GB stick cannot hold the drivers)

### 1. Get an image set

The image set is `C:\WipeBenchImages\` and is what a build copies from:

```
C:\WipeBenchImages\
├── wipebench-image.json      manifest: partition sizes, linux image name + sha256, WinPE volume serial
├── linux-part.img            8 GB raw ext4 (Debian + GRUB + the wipe engine)
├── winpe\                    boot files + DellCleaner.ps1 + sources\boot.wim
└── payload\
    ├── sources\install.wim
    ├── Drivers\              per-model driver packs + sku-index.json
    └── CustomJohn\           optional personal provisioning (opt-in at build time)
```

If you have a working stick, capture one:

```powershell
.\tools\Capture-WipeBenchImage.ps1 -DiskNumber <n> -ImageRoot C:\WipeBenchImages -IncludePayload
```

That reads partition 2 raw, copies WinPE and the payload, records the FAT32 volume serial, and
writes the manifest. **Without a stick to capture, the ext4 image must be built by hand** — a
Debian 13 install with GRUB, the `/opt/wipebench/` scripts from `linux/` in this repo, KillDisk
installed to `/opt/lsoft/`, and the BIOS scripts placed as above.

### 2. Populate the driver library

See [Drivers](#drivers). A stick works without them (`-SkipDrivers`) but injects nothing.

### 3. Build a stick

```powershell
.\tools\Build-WipeBenchUSB.ps1 -DiskNumber <n> -ImageRoot C:\WipeBenchImages
```

**This erases the target disk.** It refuses the boot/system disk and any non-USB disk unless
`-AllowInternalDisk` is passed. Useful switches:

| Switch | Effect |
|---|---|
| `-SkipDrivers` | everything except the driver tree — for a small test stick |
| `-SkipPayload` | partition and Linux only |
| `-IncludeCustom` | include `CustomJohn\` — **personal sticks only** |
| `-Force` | skip the typed `ERASE` confirmation |

Takes roughly 18 minutes for a full ~260 GB stick. It stamps a JSON build manifest into
`WIPEBENCH_USB.lock` on partitions 1 and 3 (build date, pack count, catalog version, tool age)
so a stick in the field can be told apart from an old one.

### 4. Changing only the wipe engine

The wipe engine lives inside `linux-part.img`, so editing `linux/` in this repo changes nothing
on its own. To ship a change:

```powershell
# mount linux-part.img on a Linux host, edit /opt/wipebench/*.sh, unmount, copy it back, then:
.\tools\Restore-WipeBenchLinux.ps1 -DiskNumber <n>
```

Rewrites **only** partition 2 — about 40 seconds, leaving WinPE, the drivers and the accumulated
`Evidence\` untouched, and hashes the partition back against the image afterwards. Use
`-VerifyOnly` to check a stick without writing.

---

## Drivers

The library is the master copy on the build machine; sticks are copies of it.

```powershell
.\tools\WipeBenchDrivers.ps1 -Action Audit            # health of the library
.\tools\WipeBenchDrivers.ps1 -Action Catalog          # refresh the Dell catalog
.\tools\WipeBenchDrivers.ps1 -Action Update           # what is outdated
.\tools\WipeBenchDrivers.ps1 -Action Download -Model "Latitude 5450"
.\tools\WipeBenchDrivers.ps1 -Action Index            # rebuild sku-index.json
.\tools\WipeBenchDrivers.ps1 -Action SyncStick        # mirror master -> attached stick
```

`WipeBench-Console.ps1` is a GUI over the same scripts. It opens as a standard user and asks for
elevation only when a disk operation needs it.

Non-Dell vendors have no machine-readable catalog, so each has a scraper:

```powershell
.\tools\Get-SurfaceDriverPacks.ps1   -Models 'Surface Pro 9' -Download -Expand
.\tools\Get-PanasonicDriverPacks.ps1 -Models CF33-4,FZ55-3   -Download -Expand
```

### How a pack is chosen at reimage time

`DellCleaner.ps1` resolves in this order:

1. **SystemSKU** via `Drivers\sku-index.json` — exact, and the only reliable route
2. **Match rules** via `Drivers\match-rules.json` — pattern matches, for machines whose
   reported identifiers are not equal to any folder name
3. **WMI model name** normalised to a folder name
4. **BaseBoard product** — for whiteboxes, exact match

Stages 1, 3 and 4 are all *exact* matches, which is why stage 2 exists. Two cases need it:

- **Panasonic Toughbooks** report nothing useful in `Win32_ComputerSystem.Model` and their
  `Win32_BaseBoard.Product` strings carry affixes, so `CF33-4` never equals the reported value.
- **`Surface_Pro_7+`** is unreachable by name at all: the folder-name transform replaces `+`
  with `_`, so the model string can never normalise back to the folder.

`config/match-rules.json` in this repo is the source copy; deploy it beside `sku-index.json`
in the driver root. Its rules are seeded from the **SCCM driver-apply step conditions**
(`Product LIKE '%CF33-4%'` and friends) so the stick and the task sequence cannot silently
diverge — if SCCM's conditions change, change these to match. Rules are evaluated in order and
first match wins, so specific rules precede general ones (`Surface Pro 10 5G` before
`Surface Pro 10`; `Surface Pro 7+` before `Surface Pro 7`).

Folder naming still matters for stages 3 and 4: a pack is only found if its folder matches what
the machine reports. Dell's catalog name is often *not* that string — `-Action Alias` handles it.

### Keeping this correct when packs change

Any pack change — download, update, rename, delete — can orphan a rule or leave a pack
unreachable, so there is one command that checks the whole thing:

```powershell
.\tools\WipeBenchDrivers.ps1 -Action Rules              # report
.\tools\WipeBenchDrivers.ps1 -Action Rules -Fix         # remove redundant junctions + dead rules
.\tools\WipeBenchDrivers.ps1 -Action Rules -DriversRoot T:\Drivers   # same check on a stick
```

It reports four things: rules pointing at packs that no longer exist; rules **shadowed** by an
earlier, more general rule (first match wins, so they could never fire); alias **junctions that a
rule already covers**; and packs reachable by neither a SKU entry nor a rule.

Three design decisions make this survive updates rather than needing a person to remember:

- **`-Action Alias` writes a match rule, not a junction.** A junction is copied out as a *full
  second copy* of the pack onto every stick — robocopy follows junctions even though
  `Get-ChildItem -Recurse` does not — which cost 13.9 GiB for two aliases. A rule costs nothing
  and survives a pack re-download and a stick rebuild. `-UseJunction` still forces the old
  behaviour if a real second folder is genuinely needed.
- **`-Action Normalize` refuses to rename a rule-covered folder**, and `-Action Audit` stops
  flagging one. `Surface_Pro_7+` is *supposed* to keep its `+`; normalising it to
  `Surface_Pro_7_` would silently break the rule that reaches it.
- **Rules live in the driver root, not inside a pack**, so re-downloading a pack cannot remove
  them. Updating a pack keeps the folder name, so its rule keeps working.

The rules are seeded from the SCCM driver-apply conditions, so if SCCM's conditions change,
change these to match — and re-run `-Action Rules`.

---

## Evidence

`auto_wipe.sh` appends one row per drive to `Evidence\wipe-log.csv` on partition 3, plus the full
console transcript. Columns: timestamp, host vendor/model/serial, device, drive model/serial/size,
technique, KillDisk method number, NIST 800-88 class, result.

The CSV **accumulates on the stick**, so collecting it periodically is part of the workflow —
otherwise the only copy of the record travels around in a bag.

**The transcript deliberately does not contain the Dell BIOS password.** `auto_wipe.sh` tees all
stdout to the transcript, and the transcript is archived, so anything printed during the BIOS step
would be retained in cleartext for every machine ever wiped. The BIOS scripts therefore compute
the password and hand it straight to `cctk` without displaying it. If you add output to that step,
keep it off stdout.

### Sanitisation methods

| Path | Technique | NIST SP 800-88 |
|---|---|---|
| NVMe | `nvme sanitize --sanact=4` (crypto erase) | **Purge** |
| NVMe | `nvme sanitize --sanact=2` (block erase) | **Purge** |
| NVMe fallback | `nvme format -s1` | Clear |
| SATA/SAS | KillDisk `-em=18`, single pass | Clear |

A mixed-media machine gets one from each side. The method number is defined once as
`NIST_METHOD` in `wipe_mixed.sh` so the default, the printed legend and the NVMe fallback cannot
drift apart. An overwrite is a **Clear**, never a Purge — only `nvme sanitize` is a Purge.
