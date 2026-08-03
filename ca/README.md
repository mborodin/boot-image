# Trust certificates

Drop one PEM-encoded CA certificate per file in this folder (`*.crt` or
`*.pem`). The `build-ipxe-image` GitHub Actions workflow picks up every
certificate found here and passes it to iPXE's build as a `TRUST=` root, so
the resulting `ipxe.efi` will trust HTTPS servers (e.g. your chainload
target) whose certificate chains up to one of these CAs.

Files here are safe to commit — they're public CA certificates, not keys.
