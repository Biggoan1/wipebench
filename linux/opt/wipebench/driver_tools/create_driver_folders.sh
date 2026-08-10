#!/bin/bash
# create_driver_folders.sh - Auto-create driver folder structure for WipeBench
# Usage: ./create_driver_folders.sh /path/to/driver/source

set -e

SCRIPT_VERSION="1.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_banner() {
    echo -e "${CYAN}"
    echo "=============================================================================="
    echo "                  WipeBench Driver Folder Creator v${SCRIPT_VERSION}"
    echo "=============================================================================="
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check if running as root (optional, but helpful)
if [ "$EUID" -ne 0 ]; then
    print_warning "Not running as root. You may need sudo for some operations."
fi

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/driver/source [output_path]"
    echo ""
    echo "Examples:"
    echo "  $0 /mnt/drivers"
    echo "  $0 ~/Downloads/MyDrivers /mnt/usb/drivers"
    echo ""
    exit 1
fi

SOURCE_PATH="$1"
OUTPUT_PATH="${2:-./drivers}"

print_banner

# Verify source path exists
if [ ! -d "$SOURCE_PATH" ]; then
    print_error "Source path does not exist: $SOURCE_PATH"
    exit 1
fi

# Check for .inf files in source
INF_COUNT=$(find "$SOURCE_PATH" -type f -iname "*.inf" 2>/dev/null | wc -l)
if [ "$INF_COUNT" -eq 0 ]; then
    print_error "No .inf files found in source directory!"
    print_info "Make sure the source path contains driver files."
    exit 1
fi

print_success "Found $INF_COUNT .inf files in source directory"

# Detect system information
print_info "Detecting system information..."

MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null | head -n1 | sed 's/[^a-zA-Z0-9 ]//g' | xargs)
MODEL=$(dmidecode -s system-product-name 2>/dev/null | head -n1 | sed 's/[^a-zA-Z0-9]//g' | xargs)

if [ -z "$MANUFACTURER" ] || [ "$MANUFACTURER" = "To Be Filled By O.E.M." ]; then
    print_warning "Could not auto-detect manufacturer"
    echo -n "Enter manufacturer name (Dell, HP, Lenovo, etc.): "
    read -r MANUFACTURER
fi

if [ -z "$MODEL" ] || [ "$MODEL" = "To Be Filled By O.E.M." ]; then
    print_warning "Could not auto-detect model"
    echo -n "Enter model name: "
    read -r MODEL
fi

# Normalize manufacturer name
case "$MANUFACTURER" in
    *[Dd][Ee][Ll][Ll]*)
        MANUFACTURER="Dell"
        ;;
    *[Hh][Pp]* | *[Hh]ewlett*)
        MANUFACTURER="HP"
        ;;
    *[Ll][Ee][Nn][Oo][Vv][Oo]*)
        MANUFACTURER="Lenovo"
        ;;
    *[Mm][Ii][Cc][Rr][Oo][Ss][Oo][Ff][Tt]*)
        MANUFACTURER="Microsoft"
        ;;
    *[Pp][Aa][Nn][Aa][Ss][Oo][Nn][Ii][Cc]*)
        MANUFACTURER="Panasonic"
        # Clean up Panasonic model names (remove suffixes)
        MODEL=$(echo "$MODEL" | sed 's/-[0-9]*$//' | sed 's/[^a-zA-Z0-9]//g')
        ;;
esac

# Remove spaces and special characters from model
MODEL=$(echo "$MODEL" | sed 's/[^a-zA-Z0-9]//g')

echo ""
print_info "Detected Configuration:"
echo "  Manufacturer: $MANUFACTURER"
echo "  Model: $MODEL"
echo "  Source: $SOURCE_PATH"
echo "  Output: $OUTPUT_PATH/$MANUFACTURER/$MODEL"
echo ""

# Confirm with user
read -p "Continue with this configuration? (Y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
    print_info "Cancelled by user"
    exit 0
fi

# Create target directory structure
TARGET_DIR="$OUTPUT_PATH/$MANUFACTURER/$MODEL"

print_info "Creating directory structure..."
mkdir -p "$TARGET_DIR"
print_success "Created: $TARGET_DIR"

# Copy drivers
print_info "Copying driver files..."
echo ""

rsync -av --progress "$SOURCE_PATH/" "$TARGET_DIR/" 2>&1 | grep -E "^[^ ]|%"

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    print_success "Drivers copied successfully"
else
    print_error "Failed to copy some drivers"
    exit 1
fi

# Count files copied
TOTAL_FILES=$(find "$TARGET_DIR" -type f | wc -l)
INF_FILES=$(find "$TARGET_DIR" -type f -iname "*.inf" | wc -l)

echo ""
print_success "Driver folder creation complete!"
echo ""
echo "Summary:"
echo "  Location: $TARGET_DIR"
echo "  Total files: $TOTAL_FILES"
echo "  Driver files (.inf): $INF_FILES"
echo ""

# Create a metadata file
cat > "$TARGET_DIR/DRIVER_INFO.txt" << EOF
WipeBench Driver Package
========================

Manufacturer: $MANUFACTURER
Model: $MODEL
Created: $(date)
Source: $SOURCE_PATH
Total Files: $TOTAL_FILES
Driver Files: $INF_FILES

This driver package will be automatically detected and injected by WipeBench
during Windows installation on matching hardware.
EOF

print_success "Created metadata file: DRIVER_INFO.txt"

# Show what to do next
echo ""
echo -e "${CYAN}Next Steps:${NC}"
if [[ "$OUTPUT_PATH" == *"/mnt"* ]] || [[ "$OUTPUT_PATH" == *"/media"* ]]; then
    echo "  1. Sync filesystem: sync"
    echo "  2. Unmount USB: umount $OUTPUT_PATH"
    echo "  3. USB is ready for WipeBench!"
else
    echo "  1. Copy to USB: cp -r $OUTPUT_PATH /mnt/usb/drivers/"
    echo "  2. Sync: sync"
    echo "  3. Unmount USB safely"
fi
echo ""