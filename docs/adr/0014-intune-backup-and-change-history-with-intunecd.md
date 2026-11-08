# 0014. Intune backup and change history with IntuneCD

Status: Accepted (2026-11-07, issue #68, decided with the owner: IntuneCD for backup and change history only, applying
stays with Microsoft365DSC; #68 before #18). The default for script types in point 2 is superseded by
[ADR 0015](0015-intune-backup-leaves-scripts-out-by-default.md): scripts are left out unless `IncludeScripts` is set.

## Context

The owner wants to keep the Intune state of Prod and Dev and to see what changed between runs. UTCM keeps snapshots for
7 days and reports drift every 6 hours, but has no long history (ADR 0001). The configuration repository of the
operator is the place for the desired state and its history (ADR 0004); its export from Prod (issue #27) is not built
yet. IntuneCD (almenscorner/IntuneCD, MIT, Python) backs up the Intune configuration as one file per configuration,
named by display name, made for Git. It can also update a tenant, which this toolkit must not use: Microsoft365DSC
stays the only writing path (ADR 0001), so there is one way to change Dev.

## Decision

1. **IntuneCD reads, nothing else.** Only its backup is called (`IntuneCD.run_backup`), from a small wrapper
   (`tools/intunecd/intunecd_backup.py`). Its update is never imported; a test checks the wrapper and the module.
   The backup sends only GET requests (also inside `$batch`).
2. **Fixed options:** JSON output, file names without IDs, `--ignore-omasettings` (the plain text of encrypted OMA-URI
   values is not read, it would be a secret in the files), `--skip-archive`; no Entra backup, no Autopilot device
   list, no activation lock bypass codes, no audit commits. Left out by default: `VPPusedLicenseCount`,
   `GPlaySyncTime`, `CompliancePartnerHeartbeat` (change on every read) and `ConditionalAccess` (outside Intune,
   handled by the toolkit, ADR 0003). The operator can leave out more types (`IntuneBackup.Exclude` in `config.psd1`),
   for example the script types when scripts may carry secrets.
3. **Sign-in.** The token of each tenant comes from the existing way (ADR 0013: certificate, Az.Accounts) and is
   handed to the Python process on stdin; IntuneCD takes it as `args.token` in memory. Not on the command line
   (process list), not in an environment variable, not in a file; IntuneCD's own sign-in (and its token cache file)
   is not used.
4. **Where it writes.** `ConfigRepository` in `config.psd1` names the private configuration repository (ADR 0004); it
   must be a Git work tree and must not be this toolkit or a folder around it. Each tenant goes to its own folder
   (`intune/prod`, `intune/dev`). A run writes both backups into empty folders below `History\tmp` first and replaces
   the repository folders only when both succeeded, so a failed run leaves the repository as it was.
5. **Change history = Git.** After a run Git shows what was added, changed or removed per tenant. The change is
   committed with a time stamp, the counts and the person who started it (`M365Cloning backup` as author), only the
   `intune` folder; nothing is pushed. No change, no commit.
6. **What the toolkit keeps.** `History\reports\intune-backup-<time>.json` (schema `IntuneBackup`): per tenant the
   counts and the changed paths (at most 1000), no content. One audit line, mode `backup`, counts only.
7. **Web.** A job `intune-backup` (role Applier, like the other reading jobs that use the certificates, decision of
   the owner on #14) and the page *History > Intune changes* with the list of runs and the changed files per tenant
   (routes `GET /api/intune-backups`, `/api/intune-backups/{id}`). *Areas > Intune* shows the last backup.
8. **Python.** The wrapper needs Python 3.12 and `tools/intunecd/requirements.txt` (pip-tools lock with hashes,
   apart from the web locks). `IntuneBackup.Python` names the command if it is not `python`/`python3`.

## Consequences

- The host of the job runner needs Python with IntuneCD and Git next to PowerShell 7 and Az.Accounts.
- The app registrations need Intune read permissions (validation part 15). The read-only Prod registration stays
  read only.
- The files are IntuneCD's format, not the normalised format of ADR 0004 point 2; they are the history and the
  baseline for a later freeze (milestone 2), not yet the input of an apply. Turning them into the desired state of
  Dev is part of issue #27.
- Script contents of Intune (PowerShell, shell, remediation scripts) are in the files unless the operator leaves the
  types out; the repository must stay private.
