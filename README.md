# M365Backup-Cloning

Dev tenant toolkit for Microsoft 365 / Intune: read and report differences between a Prod and a Dev tenant (UTCM), apply a mirror to the Dev tenant only (Microsoft365DSC), reset and rebuild the Dev tenant.

Status: planning. Origin: nic2045/SW-Depoyment#1585. Decisions: [`docs/adr/`](docs/adr/README.md).

## Rules
- Apply direction is Prod -> Dev only.
- No tenant data, certificates or secrets in this repository (`config.example.psd1` has placeholders only).
- Nothing runs against a real tenant without explicit approval.
- Destructive functions are guarded by a tenant ID allow list, a preview and a double confirmation.

## Third-party
See [`THIRD-PARTY.md`](THIRD-PARTY.md). License: MIT.
