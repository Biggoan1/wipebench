#!/usr/bin/env bash
# wipe_mixed.sh — Secure erase NVMe via nvme-cli sanitize/format and HDD/SATA via an
# overwrite backend: KillDisk (the licensed tool on CE sticks) or nwipe (GPL, on the
# "outside" image). The backend is chosen at run time from what is installed.
# Destroys data. Use only in an isolated lab environment.

set -euo pipefail

# Defaults (override via flags or env)
NVME_METHOD="${NVME_METHOD:-auto}"                              # auto|crypto|block|format
KILLDISK_BIN="${KILLDISK_BIN:-/opt/lsoft/KillDisk/KillDisk}"    # Path to KillDisk CLI
# The NIST 800-88 method number, defined ONCE. It was previously written in three places
# that disagreed: the default was 18, the printed legend claimed 8, and the NVMe-fallback
# path hardcoded 8 - so a single mixed-media machine could be erased with two different
# method numbers, both reported as "NIST 800-88 Rev 1". If KillDisk's method table ever
# says the number is something else, change it HERE and everything follows.
NIST_METHOD="${NIST_METHOD:-18}"                                # NIST 800-88 Rev 1
KILLDISK_METHOD="${KILLDISK_METHOD:-$NIST_METHOD}"              # override with --killdisk-method
# HDD backend. auto = KillDisk if its binary is present, else nwipe. The outside image has no
# KillDisk at all (it is licensed to one company), so it lands on nwipe without any flag.
HDD_BACKEND="${HDD_BACKEND:-auto}"                              # auto|killdisk|nwipe
NWIPE_BIN="${NWIPE_BIN:-nwipe}"
NWIPE_METHOD="${NWIPE_METHOD:-zero}"                            # one-pass zeros = NIST 800-88 Clear
NWIPE_VERIFY="${NWIPE_VERIFY:-last}"                            # off|last|all
NWIPE_REPORT_DIR="${NWIPE_REPORT_DIR:-/tmp/wipebench-nwipe}"    # per-drive log + PDF certificate; auto_wipe.sh copies these to Evidence/
POLL_INTERVAL="${POLL_INTERVAL:-10}"                            # seconds between sanitize-log polls
TIMEOUT_SEC="${TIMEOUT_SEC:-7200}"                              # 2 hours
RUN=0
YES=0
INCLUDE_ROOT=0
EXCLUDE_USB=1
DEBUG=0

usage() {
  cat <<EOF
Usage: sudo $0 [--run] [--yes] [--include-root] [--exclude-usb|--include-usb]
               [--nvme-method auto|crypto|block|format]
               [--hdd-backend auto|killdisk|nwipe]
               [--killdisk-bin /path/KillDisk] [--killdisk-method N]
               [--nwipe-method zero|one|random|dodshort|dod|gutmann] [--nwipe-verify off|last|all] [--debug]
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN=1; shift;;
    --yes) YES=1; shift;;
    --include-root) INCLUDE_ROOT=1; shift;;
    --exclude-usb) EXCLUDE_USB=1; shift;;
    --include-usb) EXCLUDE_USB=0; shift;;
    --nvme-method) NVME_METHOD="$2"; shift 2;;
    --killdisk-bin) KILLDISK_BIN="$2"; shift 2;;
    --killdisk-method) KILLDISK_METHOD="$2"; shift 2;;
    --hdd-backend) HDD_BACKEND="$2"; shift 2;;
    --nwipe-method) NWIPE_METHOD="$2"; shift 2;;
    --nwipe-verify) NWIPE_VERIFY="$2"; shift 2;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

for cmd in lsblk; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found"; exit 1; }
done

# Pick the overwrite backend for non-NVMe disks (and for NVMe drives that fail sanitize).
case "$HDD_BACKEND" in
  auto)
    if [[ -x "$KILLDISK_BIN" ]]; then HDD_BACKEND=killdisk
    elif command -v "$NWIPE_BIN" >/dev/null 2>&1; then HDD_BACKEND=nwipe
    else HDD_BACKEND=none; fi;;
  killdisk) [[ -x "$KILLDISK_BIN" ]] || { echo "KillDisk binary not found at '$KILLDISK_BIN'. Set --killdisk-bin." >&2; exit 1; };;
  nwipe)    command -v "$NWIPE_BIN" >/dev/null 2>&1 || { echo "nwipe not found ('$NWIPE_BIN')." >&2; exit 1; };;
  *) echo "Unknown --hdd-backend '$HDD_BACKEND' (auto|killdisk|nwipe)" >&2; exit 1;;
esac

# nvme-cli is optional — warn but continue (those devices go to the HDD backend instead)
if ! command -v nvme >/dev/null 2>&1; then
  echo "WARNING: nvme-cli not found — NVMe sanitize unavailable, NVMe drives go to the $HDD_BACKEND overwrite"
  NVME_METHOD="fallback"
fi

# Optional discovery table
if (( DEBUG )); then
  echo "Discovery (lsblk, full output):"
  lsblk -o NAME,TYPE,SIZE,TRAN,HOTPLUG,RM,MOUNTPOINTS | grep -v '^loop'
  echo
fi

# Build exclusion set
declare -A EXCL=()

# Exclude root device unless overridden
if (( INCLUDE_ROOT == 0 )); then
  root_src=$(findmnt -no SOURCE / || true)
  if [[ -n "$root_src" && "$root_src" != "overlay" && "$root_src" != "tmpfs" ]]; then
    root_base=$(basename "$root_src")
    root_parent=$(lsblk -no PKNAME "/dev/$root_base" 2>/dev/null | head -1 || true)
    [[ -n "$root_parent" ]] || root_parent="$root_base"
    # (an LVM/dm root reports no parent; an empty subscript would abort the script under set -u)
    [[ -n "$root_parent" ]] && EXCL["$root_parent"]=1
  fi
fi

# Exclude well-known live-media mountpoints
for mp in /cdrom /isodevice /lib/live/mount/medium /run/casper /run/mnt/medium; do
  if mountpoint -q "$mp"; then
    src=$(findmnt -no SOURCE "$mp" || true)
    [[ -z "$src" ]] && continue
    base=$(basename "$src")
    parent=$(lsblk -no PKNAME "/dev/$base" 2>/dev/null | head -1 || true)
    [[ -n "$parent" ]] || parent="$base"
    [[ -n "$parent" ]] && EXCL["$parent"]=1
  fi
done

# Exclude USB disks by transport
declare -A USBSET=()
if (( EXCLUDE_USB )); then
  while read -r name tran; do
    [[ "$tran" == "usb" ]] && USBSET["$name"]=1
  done < <(lsblk -dn -o NAME,TRAN)

  for link in /dev/disk/by-id/usb-*; do
    [[ -e "$link" ]] || continue
    dev=$(readlink -f "$link")
    base=$(basename "$dev")
    parent=$(lsblk -no PKNAME "$dev" 2>/dev/null || echo "$base")
    [[ -n "$parent" ]] && USBSET["$parent"]=1
  done
fi

# Collect only "disk" nodes, excluding loop devices
mapfile -t ALL_DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && $1 !~ /^loop/ {print $1}')

# Split into NVMe namespaces and SATA-like
declare -A NVME_CTRLS_SEEN=()
NVME_CTRLS=()
NVME_NAMESPACES=()
SATA_LIKE=()
HDD_FALLBACK=()          # NVMe drives that could not be sanitized and get overwritten instead

for d in "${ALL_DISKS[@]}"; do
  # Skip USB disks if requested
  if (( EXCLUDE_USB )) && [[ -n "${USBSET[$d]+x}" ]]; then
    EXCL["$d"]=1
    continue
  fi
  # Skip explicit exclusions
  [[ -n "${EXCL[$d]+x}" ]] && continue

  if [[ "$d" == nvme* ]]; then
    ctrl="$(lsblk -no PKNAME "/dev/$d" 2>/dev/null || true)"
    [[ -z "$ctrl" ]] && ctrl="${d%%n[0-9]*}"
    if (( DEBUG )); then
      echo "DEBUG: Mapping /dev/$d → controller /dev/$ctrl"
    fi
    if [[ -n "$ctrl" && "$ctrl" != "$d" && -z "${NVME_CTRLS_SEEN[$ctrl]+x}" ]]; then
      NVME_CTRLS_SEEN["$ctrl"]=1
      NVME_CTRLS+=("$ctrl")
    fi
    NVME_NAMESPACES+=("$d")
  else
    SATA_LIKE+=("$d")
  fi
done

if (( DEBUG )); then
  echo "DEBUG: NVME_CTRLS = ${NVME_CTRLS[*]}"
  echo "DEBUG: NVME_NAMESPACES = ${NVME_NAMESPACES[*]}"
fi

suffix=""
[[ "$EXCLUDE_USB" -eq 1 ]] && suffix="(+USB)"

# Build a printable list of excluded disks
if ((${#EXCL[@]})); then
  excluded_disks="${!EXCL[@]}"
else
  excluded_disks="none"
fi

echo "Plan (dry-run=$((1-RUN))):"
echo "- Excluded disks: $excluded_disks $suffix"
echo "- NVMe controllers to sanitize (from detection): ${NVME_NAMESPACES[*]}"
echo "- Non-NVMe disks for the $HDD_BACKEND overwrite: ${SATA_LIKE[*]:-none}"
case "$HDD_BACKEND" in
  killdisk) echo "- NVMe method: $NVME_METHOD; KillDisk method: $KILLDISK_METHOD ($NIST_METHOD=NIST 800-88 Rev 1, 3=DoD 5220.22-M)"
            echo "- NVMe drives that fail sanitize fall back to KillDisk method $NIST_METHOD";;
  nwipe)    echo "- NVMe method: $NVME_METHOD; nwipe method: $NWIPE_METHOD, verify=$NWIPE_VERIFY (a one-pass overwrite = NIST 800-88 Clear)"
            echo "- NVMe drives that fail sanitize fall back to the same nwipe overwrite";;
  none)     echo "- WARNING: no overwrite backend installed (neither KillDisk nor nwipe) - non-NVMe disks CANNOT be erased";;
esac

if [[ $RUN -eq 0 ]]; then
  echo "Dry-run only. Re-run with --run to execute."
  exit 0
fi

# ---- evidence emission (added 2026-08-10) ------------------------------------
# Emits ONE tagged line per drive. Deliberately just echo: auto_wipe.sh does all the
# mounting and CSV writing, so nothing in this destructive script can fail on a full
# disk or an unmountable partition. Format:
#   WBEV|<utc>|<dev>|<model>|<serial>|<bytes>|<technique>|<method>|<standard>|<result>
NVME_LAST_ACTION=""
NVME_LAST_STD=""
wbev() {
  local dev="$1" tech="$2" meth="$3" std="$4" res="$5" m s z
  m=$(lsblk -ndo MODEL  "/dev/$dev" 2>/dev/null | tr -d ',|' | xargs || true)
  s=$(lsblk -ndo SERIAL "/dev/$dev" 2>/dev/null | tr -d ',|' | xargs || true)
  z=$(lsblk -ndbo SIZE  "/dev/$dev" 2>/dev/null | xargs || true)
  echo "WBEV|$(date -u +%FT%TZ)|$dev|${m:-unknown}|${s:-unknown}|${z:-0}|$tech|$meth|$std|$res"
}

poll_sanitize() {
  local dev="$1" t=0
  echo "Polling sanitize status for $dev ..."
  while (( t < TIMEOUT_SEC )); do
    if out=$(nvme sanitize-log -H "$dev" 2>/dev/null); then
      if echo "$out" | grep -Eqi 'Sanitize Status.*0x101|Most Recent Sanitize Command Completed Successfully'; then
        echo "Sanitize completed on $dev"
        return 0
      fi
    fi
    sleep "$POLL_INTERVAL"
    t=$((t + POLL_INTERVAL))
  done
  echo "Timeout waiting for sanitize on $dev"
  return 1
}

erase_nvme_ctrl() {
  local dev_name="$1"
  local dev="/dev/$dev_name"

  if [[ -z "$dev_name" ]]; then
    echo "WARN: empty NVMe device name, skipping"
    return 1
  fi

  case "$NVME_METHOD" in
    crypto|auto)
      echo "nvme sanitize (crypto erase --sanact=4) on $dev ..."
      if nvme sanitize "$dev" --sanact=4; then
        poll_sanitize "$dev" || true
        NVME_LAST_ACTION="nvme sanitize crypto erase (--sanact=4)"; NVME_LAST_STD="NIST 800-88 Purge"
        return 0
      elif [[ "$NVME_METHOD" == "crypto" ]]; then
        echo "Crypto sanitize not supported on $dev."
        return 1
      fi
      ;;
  esac

  if [[ "$NVME_METHOD" == "block" || "$NVME_METHOD" == "auto" ]]; then
    echo "nvme sanitize (block erase --sanact=2) on $dev ..."
    if nvme sanitize "$dev" --sanact=2; then
      poll_sanitize "$dev" || true
      NVME_LAST_ACTION="nvme sanitize block erase (--sanact=2)"; NVME_LAST_STD="NIST 800-88 Purge"
      return 0
    fi
  fi

  if [[ "$NVME_METHOD" == "format" || "$NVME_METHOD" == "auto" ]]; then
    echo "Falling back to nvme format -s1 on $dev ..."
    if nvme format "$dev" -s 1 --force 2>/dev/null; then
      # a format is a CLEAR, not a Purge - record it honestly
      NVME_LAST_ACTION="nvme format -s1"; NVME_LAST_STD="NIST 800-88 Clear"
      return 0
    fi
    echo "nvme format failed on $dev"
    return 1
  fi

  return 1
}

sd_to_index() {
  local sd="${1:-}"
  local letters="${sd#sd}"
  local idx=0
  local i=0
  local ch=""
  local val=0
  for ((i=0; i<${#letters}; i++)); do
    ch="${letters:$i:1}"
    val=$(printf "%d" "'${ch}")
    val=$(( val - 97 ))
    if (( i > 0 )); then
      idx=$(( idx * 26 + val + 1 ))
    else
      idx=$(( idx * 26 + val ))
    fi
  done
  echo "$idx"
}

# Process NVMe namespaces — attempt nvme sanitize, fall back to the overwrite backend

for ns in "${NVME_NAMESPACES[@]}"; do
  echo "Processing NVMe namespace /dev/$ns ..."
  if [[ "$NVME_METHOD" == "fallback" ]]; then
    echo "nvme-cli unavailable — routing /dev/$ns to the $HDD_BACKEND overwrite"
    HDD_FALLBACK+=("$ns")
  elif erase_nvme_ctrl "$ns"; then
    echo "NVMe erase succeeded on /dev/$ns"
    wbev "$ns" "${NVME_LAST_ACTION:-nvme sanitize}" "-" "${NVME_LAST_STD:-NIST 800-88 Purge}" "success"
  else
    echo "NVMe erase failed on /dev/$ns — falling back to the $HDD_BACKEND overwrite"
    HDD_FALLBACK+=("$ns")
  fi
done

# ---- overwrite backends -------------------------------------------------------
# Everything non-NVMe, plus any NVMe drive that fell back. Both backends emit the same
# WBEV evidence line, and an overwrite is a CLEAR under 800-88 whatever the method number.

erase_hdd_killdisk() {
  local d idx kd_rc effective_method
  for d in "${ALL_HDD[@]}"; do
    # NVMe fallback devices use NIST 800-88 Rev 1 regardless of --killdisk-method
    if [[ " ${HDD_FALLBACK[*]} " == *" $d "* ]]; then
      # deliberately forces NIST even if --killdisk-method asked for something else
      effective_method="$NIST_METHOD"
      echo "Running KillDisk on /dev/$d (NVMe fallback, forcing NIST 800-88 Rev 1, method $effective_method) ..."
    else
      effective_method="$KILLDISK_METHOD"
      echo "Running KillDisk on /dev/$d with method $effective_method ..."
    fi

    kd_rc=0
    if [[ "$d" == sd* ]]; then
      idx=$(sd_to_index "$d")
      "$KILLDISK_BIN" -em="$effective_method" -eh="$idx" -bm || kd_rc=$?
    elif [[ "$d" == nvme* ]]; then
      # KillDisk addresses NVMe by device path directly
      "$KILLDISK_BIN" -em="$effective_method" -efd="/dev/$d" -bm || kd_rc=$?
    else
      echo "Skipping '$d' for KillDisk (no index or path mapping)."
      continue
    fi
    if (( kd_rc == 0 )); then
      wbev "$d" "KillDisk overwrite" "$effective_method" "NIST 800-88 Clear" "success"
    else
      wbev "$d" "KillDisk overwrite" "$effective_method" "NIST 800-88 Clear" "FAILED(rc=$kd_rc)"
      echo "KillDisk FAILED on /dev/$d (exit $kd_rc)" >&2
      exit "$kd_rc"      # same outcome set -e gave before, but now it is recorded first
    fi
  done
}

erase_hdd_nwipe() {
  # nwipe 0.38 (Debian trixie). One process per drive, all started together, so a two-disk
  # machine finishes in the time of its slowest disk. --nogui requires --autonuke; with a
  # device named on the command line autonuke wipes ONLY that device. --noblank because the
  # zero method already leaves the disk blank. Each drive gets its own log and PDF
  # certificate in NWIPE_REPORT_DIR; auto_wipe.sh copies that folder to Evidence/.
  local d rc worst=0 usbflag=()
  (( EXCLUDE_USB )) && usbflag=(--nousb)
  mkdir -p "$NWIPE_REPORT_DIR"
  declare -A pids=()
  for d in "${ALL_HDD[@]}"; do
    echo "Running nwipe on /dev/$d (method $NWIPE_METHOD, verify $NWIPE_VERIFY) ..."
    "$NWIPE_BIN" --autonuke --nogui --nosignals --noblank --rounds=1 "${usbflag[@]}" \
      --method="$NWIPE_METHOD" --verify="$NWIPE_VERIFY" \
      --logfile="$NWIPE_REPORT_DIR/nwipe-$d.log" --PDFreportpath="$NWIPE_REPORT_DIR" "/dev/$d" &
    pids["$d"]=$!
  done
  for d in "${ALL_HDD[@]}"; do
    rc=0; wait "${pids[$d]}" || rc=$?
    if (( rc == 0 )); then
      echo "nwipe completed on /dev/$d"
      wbev "$d" "nwipe overwrite (verify=$NWIPE_VERIFY)" "$NWIPE_METHOD" "NIST 800-88 Clear" "success"
    else
      wbev "$d" "nwipe overwrite (verify=$NWIPE_VERIFY)" "$NWIPE_METHOD" "NIST 800-88 Clear" "FAILED(rc=$rc)"
      echo "nwipe FAILED on /dev/$d (exit $rc) - see $NWIPE_REPORT_DIR/nwipe-$d.log" >&2
      worst=$rc
    fi
  done
  (( worst == 0 )) || exit "$worst"
}

ALL_HDD=(${SATA_LIKE[@]+"${SATA_LIKE[@]}"} ${HDD_FALLBACK[@]+"${HDD_FALLBACK[@]}"})

if [[ ${#ALL_HDD[@]} -gt 0 ]]; then
  case "$HDD_BACKEND" in
    killdisk) erase_hdd_killdisk;;
    nwipe)    erase_hdd_nwipe;;
    none)
      for d in "${ALL_HDD[@]}"; do wbev "$d" "none" "-" "-" "FAILED(no overwrite backend installed)"; done
      echo "ERROR: ${#ALL_HDD[@]} disk(s) could not be erased - neither KillDisk nor nwipe is installed." >&2
      exit 1;;
  esac
else
  echo "No non-NVMe disks detected for the overwrite backend."
fi

echo "All operations submitted."