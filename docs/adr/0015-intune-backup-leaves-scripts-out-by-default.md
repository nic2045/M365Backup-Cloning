# 0015. Intune backup leaves scripts out by default

Status: Accepted (2026-11-08, issue #74, decided with the owner). Supersedes the default of script types in ADR 0014
point 2.

## Context

ADR 0014 backs up all Intune types except a short default list; script types (PowerShell, shell, remediation,
compliance and custom attribute scripts) were in the files unless the operator left them out. Script contents often
carry secrets (passwords, keys, URLs with tokens). A backup that holds them by default puts secrets into the private
configuration repository without anyone deciding so. Two more points of ADR 0014 were open to doubt: whether the
repository is pushed, and whether Conditional Access is part of the backup.

## Decision

1. **Scripts are left out by default.** The wrapper (`tools/intunecd/intunecd_backup.py`) always adds the IntuneCD
   types `PowershellScripts`, `ShellScripts`, `ProactiveRemediation`, `ComplianceScripts` and `CustomAttributes` to the
   left-out types. They are backed up only when the operator sets `IntuneBackup.IncludeScripts = $true` in
   `config.psd1` (the wrapper then gets `--include-scripts`). `IntuneBackup.Exclude` still leaves out more types.
2. **No push.** The backup commits in the local configuration repository and never pushes (unchanged from ADR 0014,
   now stated as a decision): where and when the repository is shared is the operator's choice.
3. **No Conditional Access.** `ConditionalAccess` stays in the fixed default list and cannot be included: it is not
   Intune, and the owner works on Conditional Access separately (ADR 0003).

## Consequences

- The first backup after the update removes the script folders from `intune/prod` and `intune/dev` (the folders are
  replaced on each run); Git shows them as removed and their history stays in the earlier commits.
- An operator who wants script history sets `IncludeScripts` on purpose and keeps the repository private.
- The dry run of `scripts/Invoke-IntuneBackup.ps1` says whether script types are left out or backed up.
