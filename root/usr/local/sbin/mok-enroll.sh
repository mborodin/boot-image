#!/bin/bash
#
# mok-enroll.sh — runs once, only when the live system was booted with
# "mokenroll" on the kernel command line (see mok-enroll.service and the
# "Enroll Secure Boot certificate (mokutil)" grub entry added by
# ../../../editbootconfig.sh).
#
# It stages a MOK enrollment request for the iPXE signing certificate and
# reboots. IMPORTANT: this script can stage the request non-interactively,
# but it CANNOT complete it. On the next boot, shim's MokManager screen
# will appear and requires someone at the console to select "Enroll MOK" ->
# "Continue" -> "Yes" and type the password printed below / saved to
# /var/lib/mok-enroll/password. That confirmation step is a firmware/shim
# security feature and is not scriptable — it's what stops malware from
# silently enrolling trust.

set -euo pipefail

CERT="/usr/share/mok-ipxe/MOK.der"
STATE_DIR="/var/lib/mok-enroll"
MARK="$STATE_DIR/done"

mkdir -p "$STATE_DIR"

if [[ ! -f "$CERT" ]]; then
    echo "mok-enroll: certificate not found at $CERT -- did you run" >&2
    echo "            sign-ipxe-for-kiwi.sh before building the image?" >&2
    exit 1
fi

# If mokutil reports this key is already enrolled, skip straight to reboot.
if mokutil --test-key "$CERT" 2>/dev/null | grep -qi "already"; then
    echo "mok-enroll: certificate already enrolled, nothing to stage."
    touch "$MARK"
    systemctl reboot
    exit 0
fi

# Generate a one-time password and feed it to mokutil non-interactively
# (mokutil reads the new password twice from stdin when stdin isn't a tty).
PASS="$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s\n%s\n' "$PASS" "$PASS" | mokutil --import "$CERT"

umask 077
printf '%s\n' "$PASS" > "$STATE_DIR/password"
touch "$MARK"

cat <<EOF

mok-enroll: MOK import staged for $CERT
mok-enroll: one-time password: $PASS
mok-enroll:   (also saved to $STATE_DIR/password)
mok-enroll: rebooting now -- at the blue "MokManager" screen choose:
mok-enroll:   Enroll MOK -> Continue -> Yes -> (enter the password above)
mok-enroll: after that one confirmation, ipxe.efi is trusted going forward.

EOF

sleep 5
systemctl reboot
