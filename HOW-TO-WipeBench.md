# WipeBench - How To

WipeBench is a bootable USB stick that securely erases every internal drive in a PC and
then reinstalls Windows 11 on it, unattended. Plug it in, boot from it, walk away.

This file is on the stick's data partition (the big NTFS one). The engineering README
and the bench-tech operator guide are in the `Tools` folder next to it.


## 1. Before you start

* **Everything on the PC's internal drives will be destroyed.** There is no undo.
  If a drive must survive, physically remove it first. External USB drives are never
  touched, but remove them anyway so there is no confusion.
* Back up anything you need. WipeBench does not back anything up.
* Plug the PC into mains power. A laptop on battery can die mid-wipe.
* On a Dell with a BIOS/setup password: clear it in BIOS Setup first. WipeBench cannot
  clear a BIOS password it does not know, and the reinstall step needs to change the
  boot order.
* Plug the stick in. Any USB port works; USB 3 (blue) is faster.


## 2. Boot from the stick

Power on and press the boot-menu key straight away:

| Make | Key |
|---|---|
| Dell | F12 |
| HP | F9 (Esc first on some models) |
| Lenovo | F12 (or the Novo button) |
| Microsoft Surface | hold Volume-Down while pressing Power |
| Panasonic Toughbook | F2 into Setup, then Exit > Boot Override |
| Most others | F12, F11, Esc or F8 |

Pick the USB device (it may be listed as "UEFI: Samsung Flash Drive" or by the enclosure's
name). If the stick does not appear: enter BIOS Setup, make sure **USB boot** is enabled
and, if there is no option to boot the stick under Secure Boot, turn **Secure Boot** off
for the duration.


## 3. The menu

You get a text menu with five entries:

* **WinPE - Windows Deployment** (default after a wipe) - the Windows reinstall half.
  You normally never pick this by hand; the wipe reboots into it automatically.
* **WipeBench - Auto-Wipe** - the whole job: erase every internal drive, then reboot
  into the Windows reinstall. **This is the one you want.**
* **WipeBench - Wipe Only** - erase the drives and stop. Use it when the machine is being
  recycled or sold without Windows.
* **WipeBench - Linux Manual Mode** - boots to a desktop and does **nothing** to the
  drives. For looking around, checking a serial number, or reading the logs.
* Reboot / Power Off.


## 4. What Auto-Wipe does

1. **10-second countdown.** Press any key to abort. After that it is committed.
2. **Firmware steps** (Dell only): tries to disable network/HTTP boot so the machine
   cannot be re-imaged from the network later. Skipped on other makes.
3. **Drive erase.** Every internal drive is erased at the same time, so a machine with
   three drives finishes in the time of its slowest one. The method depends on the drive:

   | Drive | What runs | NIST 800-88 category |
   |---|---|---|
   | NVMe SSD | the drive's own `sanitize` command (crypto or block erase) | **Purge** |
   | SATA SSD that supports it and is not "frozen" | ATA Secure Erase, the drive's own firmware erase | **Purge** |
   | Everything else: spinning disks, frozen or locked SATA drives, drives whose firmware erase fails | `nwipe` one-pass overwrite with zeros, then a full read-back verify | **Clear** |

   A status line per drive appears every 30 seconds while it runs, for example

   ```
   [10:03:24] sda    27.73%, round 1 of 1, pass 1 of 1, eta 00:12:34, [writing]
   [10:03:24] nvme0n1  nvme sanitize running 61%, 2 min elapsed
   ```

   Spinning disks take roughly one minute per 10 GB. SSDs with a firmware erase take
   a few minutes regardless of size.

4. **Evidence.** One line per drive is written to the stick (see section 6).
5. **Reboot** into the Windows reinstall. Windows 11 is applied, the drivers matching
   the machine model are injected, the boot loader is written, and the PC restarts
   into Windows setup. Unplug the stick when you see the Windows out-of-box screen.

Wipe Only does steps 1 to 4 and then waits for a key, then powers off.

**If the wipe is interrupted** (power cut, someone pulled the stick): just boot it again.
The erase reruns from the start; nothing is left half-done that matters.


## 5. What "erased" means here

* A **Purge** (NVMe sanitize, ATA Secure Erase) makes the data unrecoverable even with
  laboratory techniques. It is what NIST 800-88 recommends for drives leaving your control.
* A **Clear** (one-pass overwrite, verified) defeats every software recovery tool. NIST
  considers one pass sufficient on modern drives. It is not a Purge; if your policy
  requires a Purge on spinning disks, physically destroy them after the wipe.
* The certificate and log always state which one actually ran on each drive. Do not
  claim more than the log says.
* A drive that reports **frozen** cannot take a firmware erase (many laptops freeze the
  drive's security at power-on). It gets the overwrite instead. That is expected.


## 6. Evidence - where the proof lives

On the stick's data partition, folder `Evidence`:

* `wipe-log.csv` - one row per drive: time (UTC), PC make / model / serial, drive model /
  serial / size, the technique used, the method, the NIST 800-88 category, and the result.
  Open it in Excel.
* `<PC-serial>_<date>.log` - the full on-screen transcript for that machine.
* `nwipe\<PC-serial>\` - for overwritten drives: nwipe's log and a **PDF certificate**
  per drive.
* `ata\<PC-serial>\` - for firmware-erased SATA drives: the hdparm transcript.

Keep this folder. Copy it off the stick periodically; it is the only record. A row whose
result is not `success` means that drive was **not** erased - deal with it before the
machine leaves.


## 7. Drivers - adding models to the stick

The reinstall injects drivers from the `Drivers` folder, matched by the machine's model
or SKU. If a model is missing, Windows still installs but may lack network or touchpad
drivers until Windows Update runs.

To add packs, on any Windows PC with internet:

1. Open `Tools\Start-WipeBenchConsole.cmd` on the stick.
2. Drivers tab. It is already pointed at this stick's `Drivers` folder.
3. Search by model (`Latitude 5450`) or Dell 4-character SKU, tick, **Download + import**.
   Dell, Microsoft Surface and Panasonic Toughbook catalogs are supported.
4. **Audit** checks the library; **What does THIS PC need?** looks up the PC you are on.

Packs are large (1 to 4 GB each). The stick needs the free space.


## 8. If something goes wrong

| You see | What it means | Do this |
|---|---|---|
| Stick not in the boot menu | USB boot off, or Secure Boot blocking it | BIOS Setup: enable USB boot; disable Secure Boot if needed |
| Menu appears, Auto-Wipe boots to a black screen then reboots | graphics quirk | pick **Linux Manual Mode** once, then retry Auto-Wipe |
| `no WIPEBENCHNTFS partition found` in the log | evidence step could not see the data partition | wipe still happened; re-seat the stick and boot **Wipe Only** to rerun with evidence |
| Row says `FAILED(...)->overwrite` then a second row for the same drive | firmware erase failed, overwrite ran instead | fine - the second row is the result |
| Row says `FAILED` with no second row | that drive was not erased | physically destroy the drive, or retry with a different port/cable |
| `secure erase not used: frozen` in the plan | drive security frozen at power-on | normal; it gets the verified overwrite |
| Dell reboots straight back into Linux after the wipe | BIOS setup password blocked the boot-order change | clear the BIOS password in Setup, boot the stick, choose **WinPE - Windows Deployment** |
| Windows installs but has no network | no driver pack for this model | add it via section 7, or use Windows Update over Ethernet |
| Machine is a Mac | Apple firmware | not supported |


## 9. What this stick deliberately does not do

* It does not clear BIOS passwords. The password-handling scripts that exist for the
  original owner's fleet are not on this stick.
* It does not carry any commercial erasure software. The overwrite tool is `nwipe`, an
  open-source (GPL) program; nothing to license or renew.
* It does not activate Windows. `install.wim` is a plain Windows 11 image; activation is
  between you and Microsoft (OEM key in firmware, or your own licensing).
* It does not need a network and should not be given one. The Linux side runs as a
  kiosk with an auto-login administrative desktop, which is fine for a wipe appliance and
  not fine for anything else.
