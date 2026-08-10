#!/usr/bin/env bash
# wipe_mixed.sh — Secure erase NVMe via nvme-cli sanitize/format and HDD/SATA via KillDisk
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
               [--killdisk-bin /path/KillDisk] [--killdisk-method N] [--debug]
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
# nvme-cli is optional — warn but continue (will fall back to KillDisk for those devices)
if ! command -v nvme >/dev/null 2>&1; then
  echo "WARNING: nvme-cli not found — NVMe sanitize unavailable, will fall back to KillDisk"
  NVME_METHOD="killdisk"
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
    root_parent=$(lsblk -no PKNAME "/dev/$root_base" 2>/dev/null || echo "$root_base")
    EXCL["$root_parent"]=1
  fi
fi

# Exclude well-known live-media mountpoints
for mp in /cdrom /isodevice /lib/live/mount/medium /run/casper /run/mnt/medium; do
  if mountpoint -q "$mp"; then
    src=$(findmnt -no SOURCE "$mp" || true)
    [[ -z "$src" ]] && continue
    base=$(basename "$src")
    parent=$(lsblk -no PKNAME "/dev/$base" 2>/dev/null || echo "$base")
    EXCL["$parent"]=1
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
KILLDISK_FALLBACK=()

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
echo "- Non-NVMe disks for KillDisk: ${SATA_LIKE[*]:-none}"
echo "- NVMe method: $NVME_METHOD; KillDisk method: $KILLDISK_METHOD ($NIST_METHOD=NIST 800-88 Rev 1, 3=DoD 5220.22-M)"
echo "- NVMe drives that fail sanitize fall back to KillDisk method $NIST_METHOD"

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

# Process NVMe namespaces — attempt nvme sanitize, fall back to KillDisk NIST 800-88 Rev 1

for ns in "${NVME_NAMESPACES[@]}"; do
  echo "Processing NVMe namespace /dev/$ns ..."
  if [[ "$NVME_METHOD" == "killdisk" ]]; then
    echo "nvme-cli unavailable — routing /dev/$ns to KillDisk fallback"
    KILLDISK_FALLBACK+=("$ns")
  elif erase_nvme_ctrl "$ns"; then
    echo "NVMe erase succeeded on /dev/$ns"
    wbev "$ns" "${NVME_LAST_ACTION:-nvme sanitize}" "-" "${NVME_LAST_STD:-NIST 800-88 Purge}" "success"
  else
    echo "NVMe erase failed on /dev/$ns — falling back to KillDisk (NIST 800-88 Rev 1)"
    KILLDISK_FALLBACK+=("$ns")
  fi
done

# Process SATA-like disks via KillDisk
# Also process any NVMe drives that fell back (nvme-cli failed or unavailable)
ALL_KILLDISK=(${SATA_LIKE[@]+"${SATA_LIKE[@]}"} ${KILLDISK_FALLBACK[@]+"${KILLDISK_FALLBACK[@]}"})

if [[ ${#ALL_KILLDISK[@]} -gt 0 ]]; then
  if ! command -v "$KILLDISK_BIN" >/dev/null 2>&1; then
    echo "KillDisk binary not found at '$KILLDISK_BIN'. Set --killdisk-bin to correct path." >&2
    exit 1
  fi

  for d in "${ALL_KILLDISK[@]}"; do
    # NVMe fallback devices use NIST 800-88 Rev 1 regardless of --killdisk-method
    if [[ " ${KILLDISK_FALLBACK[*]} " == *" $d "* ]]; then
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
    # An overwrite is a CLEAR under 800-88 regardless of the method number.
    if (( kd_rc == 0 )); then
      wbev "$d" "KillDisk overwrite" "$effective_method" "NIST 800-88 Clear" "success"
    else
      wbev "$d" "KillDisk overwrite" "$effective_method" "NIST 800-88 Clear" "FAILED(rc=$kd_rc)"
      echo "KillDisk FAILED on /dev/$d (exit $kd_rc)" >&2
      exit "$kd_rc"      # same outcome set -e gave before, but now it is recorded first
    fi
  done
else
  echo "No non-NVMe disks detected for KillDisk."
fi

echo "All operations submitted."