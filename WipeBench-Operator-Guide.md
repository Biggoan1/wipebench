# WipeBench — Operator Guide

**What it is:** a USB stick that wipes every drive in a machine to a certified standard and,
if you want, reloads Windows 11 with the right drivers — hands-off. Plug it in, boot it,
walk away.

This guide is for the person **running** the stick at the bench. For how the stick is built
or how to change what it does, see the engineering README in the WipeBench repo instead.

---

## Before you start

- **The stick protects itself.** It refuses to wipe its own USB drive, no matter what.
  You cannot accidentally erase the stick by picking the wrong disk — there is no disk
  picker; it always wipes the internal drive(s) of the machine it's plugged into.
- **Every internal drive gets wiped.** If the target machine has more than one internal
  drive, all of them are erased. Don't plug it into a machine with a drive you need to keep.
- **Don't unplug or power off mid-wipe.** Let it finish and reboot on its own. Pulling power
  during an erase can leave a drive in a bad state.
- **Confirm it's the right disk model plugged in.** WipeBench works on Dell, Panasonic
  Toughbook, and Microsoft Surface out of the box (see [Vendor differences](#vendor-differences)
  below). Anything else still gets wiped, just without the BIOS-password and driver
  automation.

---

## Quick start (the normal case)

1. Plug the stick into the machine. Power on and tap the boot-menu key (varies by
   manufacturer — F12 on Dell) to boot from USB, or set USB first in the boot order.
2. A menu appears. Leave it on the **default, highlighted entry** and let it time out
   (or press Enter) — this is full Auto mode.
3. A **10-second countdown** shows on screen. Do nothing and let it run out. (See
   [Manual mode](#manual-mode--pause-before-anything-happens) if you need to abort.)
4. The tool works through, in order:
   - Clears the BIOS/setup password (Dell only)
   - Erases every internal drive
   - Reboots automatically
   - Reloads Windows 11 with the correct drivers for that model
5. When it's done, the machine boots into a fresh, unactivated-looking Windows setup
   screen. That's the sign it's finished successfully — **do not click through OOBE**;
   the machine is ready for the next stage of the surplus process as-is.

That's the whole job for the vast majority of machines. Everything below is reference for
the cases that aren't the default.

---

## The boot menu, explained

| Menu entry | What it does | When to use it |
|---|---|---|
| **WinPE - Windows Deployment** *(default)* | Full Auto mode — wipe, then reimage | Normal intake. Just let it boot. |
| **WipeBench - Auto-Wipe** | Same wipe as above, but **stops after erasing** — no reimage | The machine is being scrapped/recycled, not resold, and doesn't need Windows put back on |
| **WipeBench - Linux Manual Mode** | Boots to a Linux desktop and **takes no destructive action at all** | You need to inspect the machine, check a serial number, or the automation isn't behaving as expected |
| Reboot / Power Off | Exactly what it says | — |

### Manual mode — pause before anything happens
If you're not sure about a machine, or you just want to look before anything gets erased,
pick **"WipeBench - Linux Manual Mode"**. It boots to a desktop and does nothing on its
own — no wipe, no BIOS changes, nothing. From there you can open a terminal to check disk
info, or just reboot back into the normal menu when you're ready.

---

## What "erased" means

Every drive is sanitized to **NIST SP 800-88** standards before Windows ever touches it:

- **NVMe / SSD drives** use the drive's own built-in secure-erase command
  (cryptographic erase where the drive supports it). This is a **Purge**-level erase —
  the strongest category in the standard.
- **Older SATA / spinning drives** get a certified single-pass overwrite (Active@ KillDisk,
  method 18). This is a **Clear**-level erase, which is the accepted standard for
  encrypted drives per our security team's guidance.
- If a drive's fast erase command fails for any reason, WipeBench automatically falls back
  to the overwrite method — nothing is left half-erased or skipped.

You don't need to pick a method or configure anything; the tool decides per-drive
automatically based on what kind of drive it finds.

---

## Evidence — what gets recorded

Every wipe writes a row to a log file that stays **on the stick** (not on the machine being
wiped): timestamp, the machine's make/model/serial, the drive's model/serial/size, which
erase technique ran, and whether it succeeded.

- **This accumulates across every machine you wipe** with that stick — it doesn't reset.
- **Periodically hand off the stick (or copy the log off it)** so the records make it into
  the surplus system's Data Destruction Certificates. A log that only ever lives on the
  stick isn't backed up anywhere else.
- If something looks wrong with a specific wipe, the full console output for that machine
  is saved alongside the log, named by that machine's serial number — useful for
  troubleshooting a specific unit later.

---

## Vendor differences

| Vendor | BIOS password cleared? | Network/HTTP boot disabled? | Drivers on reimage? |
|---|---|---|---|
| **Dell** | ✅ Automatic | ✅ Automatic | ✅ Automatic, model-specific |
| **Panasonic Toughbook** | ❌ Not automated — clear it by hand if needed | ❌ | ✅ Automatic, model-specific |
| **Microsoft Surface** | N/A (no traditional BIOS password) | N/A | ✅ Automatic, model-specific |
| **Anything else (whitebox, other OEMs)** | ❌ | ❌ | Best-effort — may reimage with no extra drivers if the model isn't in the library |

Every vendor still gets the full drive erase either way — the differences above are only
about the BIOS-automation and driver-injection steps.

---

## Troubleshooting

**The machine boots straight to Windows setup with no drivers / no network / no touchpad**
The driver library didn't have a match for that exact model. This is rare but happens with
brand-new hardware the library hasn't caught up to yet. Note the exact model and let
whoever maintains WipeBench know — the fix is usually a same-day driver-pack add, not a
tool problem.

**It rebooted into the BIOS/setup screen instead of continuing**
This can happen on the very first boot after a wipe if the boot order needs a nudge. Enter
the BIOS, confirm the internal drive shows up (it should now say "Windows Boot Manager" or
similar), set it first in boot order, save, and let it continue. This is a one-time
firmware quirk, not a sign anything went wrong with the erase.

**The countdown ran out before I could react**
That's normal — it's meant to. If you need to stop something from happening, reboot the
machine immediately and pick **Linux Manual Mode** instead next time; nothing destructive
happens until the countdown actually completes.

**A drive's erase failed / says FAILED in the log**
The machine will still reboot and continue automatically — WipeBench doesn't stop the
whole process for one failed drive. Check the Evidence log for that machine afterward; a
FAILED row means that specific drive needs manual attention (it may be dying, or DRM-locked
in an unusual way) before the machine can be certified as sanitized. Don't resell it based
on an automatic pass if the log shows a failure.

**Nothing happens when I boot from the stick**
Confirm the machine actually booted from USB (check the boot-menu key for that
manufacturer) and that UEFI/legacy boot mode matches what the stick expects (UEFI). If it
still won't boot, try a different USB port — some older machines are picky about which
ports enumerate at boot.

---

## What this tool will never do

- It will never touch its own USB drive.
- It will never silently skip a drive — every drive gets a logged outcome, success or
  failure.
- It will never apply one person's personal software/settings to a team machine unless
  that stick was specifically built to include them.

---

*This is an operator's guide. For how WipeBench is built, how driver packs are managed, or
how to build your own stick, see the engineering README that ships with the WipeBench
source.*
