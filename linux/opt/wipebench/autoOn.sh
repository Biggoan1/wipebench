#!/bin/bash
# schedule_poweron.sh - Schedule BIOS auto-power-on for 2 minutes from now

CCTK="/opt/dell/dcc/cctk"

# Check if CCTK exists
if [ ! -f "$CCTK" ]; then
    echo "ERROR: CCTK not found at $CCTK"
    exit 1
fi

# Check if this is a Dell system
if ! "$CCTK" 2>&1 | grep -q "Dell"; then
    echo "WARNING: Not a Dell system, skipping auto-power-on"
    exit 0
fi

echo "Syncing hardware clock with system time..."
# CCTK always interprets hardware clock as local time
hwclock --systohc --localtime

echo "Setting BIOS to power on in 2 minutes..."

# Get current time + 2 minutes
WAKE_TIME=$(date -d "+2 minutes" "+%H:%M")
WAKE_HH=$(echo "$WAKE_TIME" | cut -d: -f1)
WAKE_MM=$(echo "$WAKE_TIME" | cut -d: -f2)

echo "Current time: $(date "+%H:%M")"
echo "Scheduled wake: $WAKE_HH:$WAKE_MM"

# Set auto-power-on
"$CCTK" --autoon=everyday --autoonhr="$WAKE_HH" --autoonmn="$WAKE_MM"

if [ $? -eq 0 ]; then
    echo ""
    echo "SUCCESS: Auto-power-on scheduled for $WAKE_HH:$WAKE_MM"
else
    echo ""
    echo "ERROR: Failed to set auto-power-on"
    exit 1
fi