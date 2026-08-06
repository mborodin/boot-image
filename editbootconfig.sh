#!/bin/bash
#
# editbootconfig.sh — kiwi-ng "editbootconfig" hook (see config.xml's
# <type editbootconfig="editbootconfig.sh">). KIWI calls this script right
# before the bootloader is installed into the ISO, with the directory that
# contains the (in-progress) image/boot structure as its first argument.
#
# It:
#   1. Copies the pre-signed ipxe.efi next to grubx64.efi/BOOTX64.EFI.
#   2. Rewrites every grub.cfg it finds so the menu has, in order:
#        1) iPXE boot
#        2) Enroll Secure Boot certificate (mokutil)
#        3) Live OS            <- KIWI's original entry, unchanged, default
#
# NOTE ON ROBUSTNESS: KIWI's exact directory layout at this hook point can
# vary by version, which is why this script leans on `find` instead of
# hardcoded paths, and clones the ORIGINAL live menuentry byte-for-byte
# (title + one appended kernel parameter) instead of reconstructing kernel/
# initrd paths from scratch. Run your first build with `kiwi-ng --debug` and
# check the echoed diagnostics below if something doesn't line up.

set -euo pipefail

# BOOT_ROOT="${1:-.}"
BOOT_ROOT_RAW="${1:-.}"
BOOT_ROOT="$BOOT_ROOT_RAW"

if [[ ! -d "$BOOT_ROOT" && "$BOOT_ROOT" == *:* ]]; then
    BOOT_ROOT_STRIPPED="${BOOT_ROOT#*:}"
    if [[ -d "$BOOT_ROOT_STRIPPED" ]]; then
        BOOT_ROOT="$BOOT_ROOT_STRIPPED"
    fi
fi

if [[ ! -d "$BOOT_ROOT" ]]; then
    echo "editbootconfig.sh: ERROR - BOOT_ROOT is not a directory: $BOOT_ROOT_RAW (normalized: $BOOT_ROOT)" >&2
    exit 1
fi

echo "editbootconfig.sh: scanning under: $BOOT_ROOT" >&2

# --- Locate the signed iPXE payload -----------------------------------------
IPXE_SRC=""
for candidate in \
    "$BOOT_ROOT"/usr/share/mok-ipxe/ipxe.efi \
    "$(dirname "$0")"/root/usr/share/mok-ipxe/ipxe.efi \
    "$(dirname "$0")"/payload/ipxe.efi \
    /image-root/ipxe.efi
do
    if [[ -f "$candidate" ]]; then IPXE_SRC="$candidate"; break; fi
done
if [[ -z "$IPXE_SRC" ]]; then
    IPXE_SRC="$(find "$BOOT_ROOT" -iname 'ipxe.efi' 2>/dev/null | head -1 || true)"
fi
if [[ -z "$IPXE_SRC" ]]; then
    echo "editbootconfig.sh: ERROR - could not find a signed ipxe.efi anywhere" >&2
    echo "                   under $BOOT_ROOT. Did you run sign-ipxe-for-kiwi.sh" >&2
    echo "                   before 'kiwi-ng system build'?" >&2
    exit 1
fi
echo "===> editbootconfig.sh: using ipxe.efi: $IPXE_SRC" >&2

# --- Locate/create EFI/BOOT staging directory -------------------------------
# In KIWI editbootconfig phase BOOTX64.EFI may not exist yet.
# We must place ipxe.efi into the EFI tree that KIWI later packs into the ISO.
EFI_BOOT_DIR=""

for d in \
    "$BOOT_ROOT/EFI/BOOT" \
    "$BOOT_ROOT/boot/efi/EFI/BOOT"
do
    if [[ -d "$d" ]]; then
        EFI_BOOT_DIR="$d"
        break
    fi
done

if [[ -z "$EFI_BOOT_DIR" ]]; then
    # Preferred location for live-media staging (picked up later by KIWI)
    EFI_BOOT_DIR="$BOOT_ROOT/EFI/BOOT"
    mkdir -p "$EFI_BOOT_DIR"
fi

echo "===> copy signed ipxe.efi to $EFI_BOOT_DIR/ipxe.efi" >&2
cp -v "$IPXE_SRC" "$EFI_BOOT_DIR/ipxe.efi" >&2

echo "===> verify EFI tree (depth 3):" >&2
find "$BOOT_ROOT/EFI" -maxdepth 3 -type f 2>/dev/null | sort >&2 || true

# --- Rewrite every grub.cfg found -------------------------------------------
# mapfile -t GRUB_CFGS < <(find "$BOOT_ROOT" -iname 'grub.cfg' 2>/dev/null)

# echo "=============================="
# echo "| grub.cfg                   |"
# echo "+----------------------------+"
# echo "| dir: $BOOT_ROOT            |"
# echo "+----------------------------+"
# ls -laR "$BOOT_ROOT"/boot/grub2/
# echo "+----------------------------+"
# file "$BOOT_ROOT"/boot/grub2/grub.cfg || true
# echo "+----------------------------+"
# find -L "$BOOT_ROOT"/boot -type f -name 'grub.cfg' 2>/dev/null || true
# echo "+----------------------------+"
# find -L "$BOOT_ROOT" -iname 'grub.cfg' 2>/dev/null || true
# echo "=============================="


if [[ ! -f "$BOOT_ROOT"/boot/grub2/grub.cfg ]]; then
    echo "editbootconfig.sh: ERROR - no grub.cfg found under $BOOT_ROOT/boot/grub2" >&2
    exit 1
fi

# if [[ "${#GRUB_CFGS[@]}" -eq 0 ]]; then
#     echo "editbootconfig.sh: ERROR - no grub.cfg found under $BOOT_ROOT" >&2
#     exit 1
# fi


# for cfg in "${GRUB_CFGS[@]}"; do

cfg="$BOOT_ROOT"/boot/grub2/grub.cfg
echo "editbootconfig.sh: patching $cfg" >&2
python3 - "$cfg" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, "r") as f:
    original = f.read()


def find_first_menuentry(text):
    start = text.find("menuentry")
    if start == -1:
        return None
    brace_start = text.find("{", start)
    if brace_start == -1:
        return None
    depth = 0
    i = brace_start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
        i += 1
    return None


span = find_first_menuentry(original)
if span is None:
    print("editbootconfig.sh: no menuentry block found, leaving grub.cfg untouched",
          file=sys.stderr)
    sys.exit(0)

s, e = span
live_block = original[s:e]

# Clone the live entry for the mokutil-enrollment path, appending a kernel
# parameter that mok-enroll.service's ConditionKernelCommandLine matches on.
mok_block = live_block
mok_block = re.sub(
    r'menuentry\s+"[^"]*"',
    'menuentry "Enroll Secure Boot certificate (mokutil)"',
    mok_block,
    count=1,
)
mok_block = re.sub(
    r'^(\s*linux(?:16|efi)?\s+\S+.*)$',
    r'\1 mokenroll',
    mok_block,
    count=1,
    flags=re.MULTILINE,
)

ipxe_block = (
    'menuentry "iPXE boot" {\n'
    "    insmod chain\n"
    "    insmod fat\n"
    "    insmod part_gpt\n"
    "    chainloader /EFI/BOOT/ipxe.efi\n"
    "}\n"
)

new_content = (
    ipxe_block
    + "\n"
    + mok_block
    + "\n"
    + original
    + '\nset default="2"\n'
)

with open(path, "w") as f:
    f.write(new_content)

print("editbootconfig.sh: inserted iPXE + mokutil entries, default -> Live OS (index 2)",
      file=sys.stderr)
PYEOF
# done

echo "editbootconfig.sh: done" >&2
