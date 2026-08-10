#!/bin/bash
# WipeBench Auto-Wipe Script with HTTP/HTTPS Boot Disabling
# This script runs automatically when Linux boots from the WipeBench USB
# Supports two modes: Full automation (default) or Wipe-Only mode

set -e

LOG_FILE="/tmp/wipebench_autowipe.log"
CCTK="/opt/dell/dcc/cctk"

# Detect vendor via DMI
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
IS_DELL=false
IS_PANASONIC=false

case "$VENDOR" in
    *Dell*|*DELL*)
        IS_DELL=true
        ;;
    *Panasonic*|*PANASONIC*)
        IS_PANASONIC=true
        ;;
esac

# Check for wipe-only mode (passed via kernel command line)
# MANUAL MODE: the GRUB "Linux Manual Mode" entry passes wipebench.manual so this
# script takes NO destructive action. Without it, manual mode still ran the full
# auto-wipe and only a keypress inside the 10s countdown saved the disk.
if grep -q "wipebench.manual" /proc/cmdline; then
    echo "======================================"
    echo "WipeBench MANUAL MODE"
    echo "Time: $(date)"
    echo "======================================"
    echo ""
    echo "Booted with wipebench.manual - taking NO action:"
    echo "  - no BIOS password clear"
    echo "  - no boot-order / network-boot changes"
    echo "  - NO DRIVE WIPING"
    echo ""
    echo "The desktop is yours. To wipe this machine, reboot and pick"
    echo "\"WipeBench - Auto-Wipe\" from the GRUB menu."
    echo ""
    echo "Press any key to close this window..."
    read -n 1 -s
    exit 0
fi

WIPE_ONLY=false
if grep -q "wipebench.wipeonly" /proc/cmdline; then
    WIPE_ONLY=true
fi

# Redirect all output to log file
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "======================================"
if [ "$WIPE_ONLY" = true ]; then
    echo "WipeBench WIPE-ONLY Mode Started"
else
    echo "WipeBench Auto-Wipe Started"
fi
echo "Time: $(date)"
echo "Vendor: $VENDOR"
echo "======================================"

# 10-second countdown with abort option
if [ "$WIPE_ONLY" = true ]; then
    echo ""
    echo "WIPE-ONLY MODE - WIPE WILL BEGIN IN 10 SECONDS"
    echo "Press ANY key to abort..."
    echo ""
else
    echo ""
    echo "AUTOMATED WIPE WILL BEGIN IN 10 SECONDS"
    echo "Press ANY key to abort..."
    echo ""
fi

for i in {10..1}; do
    echo -n "$i... "
    read -t 1 -n 1 && {
        echo ""
        echo "ABORTED by user"
        exit 0
    }
done
echo ""

if [ "$WIPE_ONLY" = true ]; then
    echo "Starting wipe-only process..."
else
    echo "Starting automated process..."
fi

# ============================================
# BIOS PASSWORD CLEARING (Dell only)
# ============================================
echo ""
echo "=== Step 1: BIOS Password Clearing ==="

if [ "$IS_DELL" = true ] && [ -f "$CCTK" ]; then
    echo "Dell system detected, running CCTK commands..."

    if [ -f "/opt/wipebench/bios_clear.sh" ]; then
        bash /opt/wipebench/bios_clear.sh
    else
        echo "WARNING: bios_clear.sh not found, skipping BIOS password clear"
    fi
elif [ "$IS_PANASONIC" = true ]; then
    echo "Panasonic system detected - BIOS password clearing not supported, skipping"
else
    echo "Non-Dell/Panasonic system or CCTK not found - skipping BIOS password clear"
fi

# ============================================
# DISABLE HTTP/HTTPS BOOT (Dell only)
# ============================================
echo ""
echo "=== Step 2: Disable HTTP/HTTPS Boot ==="

if [ "$IS_DELL" = true ] && [ -f "$CCTK" ]; then
    echo "Attempting to disable HTTP Boot..."

    HTTP_DISABLED=false

    # Option 1: --uefinwstack=disabled (UEFI Network Stack)
    if $CCTK --uefinwstack=disabled --valsetuppwd="" 2>&1 | grep -qv "usage\|Usage\|error\|Error"; then
        echo "✓ UEFI Network Stack disabled using --uefinwstack"
        HTTP_DISABLED=true
    # Option 2: --httpboot=disabled
    elif $CCTK --httpboot=disabled --valsetuppwd="" 2>&1 | grep -qv "usage\|Usage\|error\|Error"; then
        echo "✓ HTTP boot disabled using --httpboot"
        HTTP_DISABLED=true
    # Option 3: --HttpBoot=Disabled (capital H)
    elif $CCTK --HttpBoot=Disabled --valsetuppwd="" 2>&1 | grep -qv "usage\|Usage\|error\|Error"; then
        echo "✓ HTTP boot disabled using --HttpBoot"
        HTTP_DISABLED=true
    # Option 4: --networkboot=disabled
    elif $CCTK --networkboot=disabled --valsetuppwd="" 2>&1 | grep -qv "usage\|Usage\|error\|Error"; then
        echo "✓ Network boot disabled using --networkboot"
        HTTP_DISABLED=true
    # Option 5: --NetworkBoot=Disabled
    elif $CCTK --NetworkBoot=Disabled --valsetuppwd="" 2>&1 | grep -qv "usage\|Usage\|error\|Error"; then
        echo "✓ Network boot disabled using --NetworkBoot"
        HTTP_DISABLED=true
    else
        echo "⚠ HTTP/Network boot disable not supported on this model or already disabled"
        HTTP_DISABLED=false
    fi

    echo "HTTP/HTTPS Boot configuration attempt complete"
elif [ "$IS_PANASONIC" = true ]; then
    echo "Panasonic system detected - HTTP/HTTPS boot disable not supported via automation, skipping"
else
    echo "Non-Dell system - skipping HTTP/HTTPS boot disable"
fi

# ============================================
# DRIVE WIPING
# ============================================
echo ""
echo "=== Step 3: Drive Wiping ==="

if [ -f "/opt/wipebench/wipe_mixed.sh" ]; then
    echo "Starting drive wipe process..."
    bash /opt/wipebench/wipe_mixed.sh --run
else
    echo "ERROR: wipe_mixed.sh not found!"
    exit 1
fi

# ============================================
# EVIDENCE  (added 2026-08-10)
# ============================================
# The console log lives on tmpfs and dies at reboot, so nothing durable recorded what
# was erased. Append one CSV row per drive to the stick's NTFS payload partition.
# EVERY step is best-effort: this script runs under `set -e`, and a full disk or an
# unmountable partition must never affect the wipe that already happened.
echo ""
echo "=== Step 4: Recording evidence ==="
record_evidence() {
  local part mnt csv hv hm hs n=0
  part=$(blkid -L WIPEBENCHNTFS 2>/dev/null || true)
  if [ -z "$part" ]; then
    echo "  no WIPEBENCHNTFS partition found - evidence stays in $LOG_FILE only"; return 0
  fi
  mnt=$(mktemp -d) || return 0
  if ! mount -t ntfs-3g -o rw "$part" "$mnt" 2>/dev/null && ! mount "$part" "$mnt" 2>/dev/null; then
    echo "  could not mount $part read-write - evidence stays in $LOG_FILE only"
    rmdir "$mnt" 2>/dev/null || true; return 0
  fi
  mkdir -p "$mnt/Evidence" 2>/dev/null || true
  csv="$mnt/Evidence/wipe-log.csv"
  if [ ! -f "$csv" ]; then
    echo "timestamp_utc,host_vendor,host_model,host_serial,device,drive_model,drive_serial,size_bytes,technique,killdisk_method,standard,result" > "$csv" 2>/dev/null || true
  fi
  hv=$(cat /sys/class/dmi/id/sys_vendor    2>/dev/null | tr -d ',' | xargs || true)
  hm=$(cat /sys/class/dmi/id/product_name  2>/dev/null | tr -d ',' | xargs || true)
  hs=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d ',' | xargs || true)
  while IFS='|' read -r _t ts dev dmodel dserial dsize tech meth std res; do
    [ -n "${dev:-}" ] || continue
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ts" "${hv:-unknown}" "${hm:-unknown}" "${hs:-unknown}" "$dev" \
      "$dmodel" "$dserial" "$dsize" "$tech" "$meth" "$std" "$res" >> "$csv" 2>/dev/null || true
    n=$((n+1))
  done < <(grep '^WBEV|' "$LOG_FILE" 2>/dev/null || true)
  # keep the full transcript too - the CSV is the index, this is the detail
  cp "$LOG_FILE" "$mnt/Evidence/${hs:-unknown}_$(date -u +%Y%m%d-%H%M%S).log" 2>/dev/null || true
  sync 2>/dev/null || true
  umount "$mnt" 2>/dev/null || true
  rmdir  "$mnt" 2>/dev/null || true
  echo "  recorded $n drive row(s) to Evidence/wipe-log.csv on the stick"
}
record_evidence || echo "  evidence step failed - continuing; the wipe itself is unaffected"

# ============================================
# COMPLETION
# ============================================
echo ""
echo "======================================"
if [ "$WIPE_ONLY" = true ]; then
    echo "WIPE-ONLY PROCESS COMPLETE"
    echo "Time: $(date)"
    echo ""
    echo "Drive wiping has completed successfully."
    echo ""
    echo "======================================"
    echo ""
    echo "Press any key to power off..."
    read -n 1 -s
    echo ""
    echo "Powering off system..."
else
    echo "WipeBench Auto-Wipe COMPLETE"
    echo "Time: $(date)"
    echo "======================================"
    echo ""
    echo "System will reboot in 5 seconds..."
    echo ""
    sleep 5
fi

# Full power off (not reboot) to ensure USB re-enumeration
#systemctl poweroff --force --force
systemctl reboot