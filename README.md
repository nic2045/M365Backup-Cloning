# M365Backup-Cloning

Dev tenant toolkit for Microsoft 365 / Intune: read and report differences between a production and a dev tenant (UTCM), apply a mirror to the dev tenant only (Microsoft365DSC), reset and rebuild the dev tenant.

Status: planning. Origin: nic2045/SW-Depoyment#1585.

Rules:
- Apply direction is Prod -> Dev only.
- No tenant data, certificates or secrets in this repository.
- Nothing runs against a real tenant without explicit approval.
