#!/usr/bin/env bash
#
# sign-ipxe-for-kiwi.sh — run this BEFORE `kiwi-ng system build`.
#
# Takes your unsigned ipxe.efi, generates a self-signed MOK key/cert (or
# reuses one you already have), signs ipxe.efi with it, and drops both into
# this image description's root overlay at root/usr/share/mok-ipxe/, so:
#   - editbootconfig.sh can pick up ipxe.efi and place it at /EFI/BOOT/ipxe.efi
#   - mok-enroll.sh (running inside the booted live system) can read MOK.der
#     to stage the MOK enrollment request
#
# Usage:
#   ./sign-ipxe-for-kiwi.sh -i /path/to/ipxe.efi [-k key.pem -c cert.pem]
#
# The generated (or reused) key/cert are also copied to ./MOK.key / MOK.crt
# / MOK.der next to this script -- keep MOK.key private. Re-run this script
# with -k/-c pointing at that same key/cert if you rebuild ipxe.efi later,
# so you don't have to re-enroll a new MOK on machines that already trust it.

set -euo pipefail

DESC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "sign-ipxe-for-kiwi.sh: DESC_DIR=$DESC_DIR" >&2

OUT_DIR="$DESC_DIR/root/usr/share/mok-ipxe"
echo "sign-ipxe-for-kiwi.sh: OUT_DIR=$OUT_DIR" >&2


IPXE_SRC=""
KEY=""
CERT=""
CN="iPXE Secure Boot MOK"

usage() {
    echo "Usage: $0 -i <ipxe.efi> [-k key.pem -c cert.pem] [-n \"CN\"]" >&2
    exit 1
}

while getopts "i:k:c:n:h" opt; do
    case "$opt" in
        i) IPXE_SRC="$OPTARG" ;;
        k) KEY="$OPTARG" ;;
        c) CERT="$OPTARG" ;;
        n) CN="$OPTARG" ;;
        h|*) usage ;;
    esac
done

[[ -z "$IPXE_SRC" ]] && usage
[[ -f "$IPXE_SRC" ]] || { echo "error: ipxe.efi not found: $IPXE_SRC" >&2; exit 1; }
if [[ -n "$KEY" && -z "$CERT" ]] || [[ -z "$KEY" && -n "$CERT" ]]; then
    echo "error: -k and -c must be given together" >&2; exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not found (install sbsigntools/sbsigntool + openssl)" >&2; exit 1; }; }
need openssl
need sbsign

mkdir -p "$OUT_DIR"

if [[ -z "$KEY" ]]; then
    if [[ -f "$DESC_DIR/MOK.key" && -f "$DESC_DIR/MOK.crt" ]]; then
        echo "Reusing existing $DESC_DIR/MOK.key / MOK.crt"
        KEY="$DESC_DIR/MOK.key"
        CERT="$DESC_DIR/MOK.crt"
    else
        echo "Generating new self-signed MOK key/cert (CN=\"$CN\")..."
        KEY="$DESC_DIR/MOK.key"
        CERT="$DESC_DIR/MOK.crt"
        openssl req -newkey rsa:2048 -nodes -keyout "$KEY" \
            -new -x509 -sha256 -days 3650 \
            -subj "/CN=$CN/" \
            -out "$CERT"
        chmod 600 "$KEY"
    fi
fi

openssl x509 -in "$CERT" -outform DER -out "$DESC_DIR/MOK.der"

echo "Signing $IPXE_SRC ..."
sbsign --key "$KEY" --cert "$CERT" --output "$OUT_DIR/ipxe.efi" "$IPXE_SRC"
cp "$DESC_DIR/MOK.der" "$OUT_DIR/MOK.der"

echo "===> verify signed files: $OUT_DIR/ipxe.efi $OUT_DIR/MOK.der" >&2
md5sum "$OUT_DIR/ipxe.efi" >&2
md5sum "$OUT_DIR/MOK.der" >&2

cat <<EOF

Done.
  Signed payload : $OUT_DIR/ipxe.efi
  MOK certificate: $OUT_DIR/MOK.der  (staged into the live image for mok-enroll.sh)
  Private key    : $KEY   (keep this safe -- reuse it for future rebuilds)

You can now run:
  sudo kiwi-ng system build --description "$DESC_DIR" --target-dir ./build \\
      --set-repo https://download.opensuse.org/tumbleweed/repo/oss/
EOF
