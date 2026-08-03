# ipxe-secureboot-live

A kiwi-ng image description for a minimal openSUSE Tumbleweed live ISO with
three GRUB boot entries:

1. **iPXE boot** — chainloads a signed `ipxe.efi`
2. **Enroll Secure Boot certificate (mokutil)** — boots this same live system
   with `mokenroll` on the kernel command line, which triggers a one-shot
   service that stages a MOK enrollment request for the iPXE certificate and
   reboots
3. **Live OS** — KIWI's normal live boot entry, unchanged, and the default

Secure Boot chain: firmware trusts `shim` (openSUSE's shim package, already
in `db` on essentially all hardware/OVMF) → shim trusts `grub2` (also
openSUSE-signed, no enrollment needed) → grub trusts `ipxe.efi` only because
you signed it with a self-generated MOK key and enrolled that one certificate
via entry 2.

## Files

| File | Purpose |
|---|---|
| `config.xml` | KIWI image description (minimal Tumbleweed live ISO, UEFI) |
| `config.sh` | Chroot finishing script: enables NetworkManager, sshd, the `mok-enroll` service |
| `editbootconfig.sh` | KIWI's `editbootconfig` hook — injects the iPXE + mokutil menu entries into the generated `grub.cfg` and copies `ipxe.efi` into `/EFI/BOOT/` |
| `sign-ipxe-for-kiwi.sh` | Run **before** building: signs your `ipxe.efi` with a MOK key and stages it + the cert into the root overlay |
| `root/etc/systemd/system/mok-enroll.service` | Gated by `ConditionKernelCommandLine=mokenroll` |
| `root/usr/local/sbin/mok-enroll.sh` | Stages the MOK import, then reboots |
| `ca/` | Trust root certificates (`*.crt`/`*.pem`) embedded into `ipxe.efi` via `TRUST=` by the CI build |
| `.github/workflows/build-ipxe-image.yml` | Manually triggered workflow: clone iPXE, build+sign `ipxe.efi`, build the ISO, publish a release |

## Build steps

```bash
# 1. Sign your iPXE EFI build with a (generated or existing) MOK key
./sign-ipxe-for-kiwi.sh -i /path/to/your/ipxe.efi

# 2. Build the ISO (needs kiwi-ng + repo access; run on/for openSUSE Tumbleweed)
sudo kiwi-ng system build \
    --description . \
    --target-dir ./build \
    --set-repo https://download.opensuse.org/tumbleweed/repo/oss/

# 3. Test in QEMU with OVMF (secure boot vars template varies by distro path)
sudo qemu-system-x86_64 -m 2048 -enable-kvm \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.secboot.fd \
    -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
    -cdrom ./build/*.iso
```

## What to verify on your first real build

I built and unit-tested the signing pipeline (openssl → sbsign) and the
`grub.cfg` rewrite logic (Python block-matching in `editbootconfig.sh`)
directly, but I could not run an actual `kiwi-ng system build` in my sandbox
— it needs root, loop devices, and hundreds of MB from
`download.opensuse.org`. Two things are worth double-checking on a real
build:

- **`editbootconfig`'s exact argument/cwd contract.** KIWI's docs describe it
  as "called right before the bootloader is installed... relative to the
  directory containing the image structure," which is why the script uses
  `find` instead of hardcoded paths. If it can't locate `BOOTX64.EFI`,
  `grub.cfg`, or `ipxe.efi`, it prints a clear error to stderr rather than
  failing silently — run with `kiwi-ng --debug` and check that output first.
- **Package names.** `shim`, `mokutil`, `grub2-x86_64-efi`, `dracut-kiwi-live`
  are current openSUSE Tumbleweed package names as of writing; zypper will
  tell you immediately if any have been renamed.

## Automated builds via GitHub Actions

`.github/workflows/build-ipxe-image.yml` is a manually triggered
(`workflow_dispatch`) workflow that runs the whole pipeline end to end:
clones `ipxe/ipxe`, generates a `boot.ipxe` that just `chain`s to the URL
you give it, builds `bin-x86_64-efi/ipxe.efi` trusting every certificate in
[`ca/`](ca/), signs it via `sign-ipxe-for-kiwi.sh`, builds the kiwi-ng ISO,
and publishes it as a GitHub release (title = the `release_name` input, tag
= a UTC timestamp in `YYYYMMDDHHmm` form).

Inputs:

| Input | Required | Description |
|---|---|---|
| `chainload_url` | yes | URL the generated `boot.ipxe` chainloads to |
| `release_name` | yes | Title of the created GitHub release |
| `ipxe_ref` | no (default `master`) | Branch/tag/commit of `ipxe/ipxe` to build |

Repository secrets required:

| Secret | Contents |
|---|---|
| `MOK_KEY` | PEM-encoded MOK private key |
| `MOK_CRT` | PEM-encoded MOK certificate |

Put these once and reuse them across builds (so machines that already
enrolled the MOK don't need to re-enroll) — see `sign-ipxe-for-kiwi.sh` for
how they're consumed.

## The one step that can't be scripted

`mok-enroll.sh` can stage the MOK import and reboot automatically, but the
actual enrollment confirmation — shim's blue **MokManager** screen asking
"Enroll MOK? yes/no" plus a password — requires a key press at the physical
console (or console redirection) on that next boot. This is intentional: it's
what stops something else from silently trusting its own signing key. It's a
one-time step per machine (or per OVMF vars file for VMs); after that,
`ipxe.efi` boots under Secure Boot with no further prompts.
