# Working rules for Claude

## Purpose
Dev tenant toolkit (origin: nic2045/SW-Depoyment#1585). Read and report differences Prod -> Dev (UTCM), apply to Dev only (Microsoft365DSC), reset and rebuild the Dev tenant. See `docs/adr/`.

## Hard rules
- Never run anything against a real tenant without explicit approval from the user in the current chat.
- Apply direction is Prod -> Dev only. Writing to a Prod tenant is not implemented and must not be added.
- No tenant IDs, customer names, certificates, secrets or exports in the repository or in test data. Tests use mocks only. Real configuration lives in `config.psd1` (git-ignored); only `config.example.psd1` is committed.
- Destructive functions (reset) work only on tenant IDs listed in the local config, show a preview first and need a double confirmation. Admin, service and break-glass accounts are never touched.
- Conditional Access policies are created Report-only or disabled. Never use `Ensure = Absent` in an automatic run. Role assignments go through groups.
- Groups are matched by name, not by ID.

## Generic tool set
- This repository is a generic tool set that customers clone and run for their own environment (one instance per customer, one Prod/Dev pair). No customer information, customer structure, tenant data or customer-specific paths in code, docs, tests or issues. Wording is neutral ("your tenants").

## Branches and pull requests
- One PR per task, always from fresh `origin/main` (`git fetch origin main && git checkout -B <branch> origin/main`). No stacked PRs. Never push to `main`, never merge.
- Squash merge is the default. Before each push fetch `origin/main` and merge it in when behind (no rebase on shared branches).
- Each PR text contains `Closes #<nr>`.

## Requirements
- Each non-trivial request becomes a GitHub issue first (short title, goal and acceptance in 2-3 lines, label `requirement`). Small things need no issue.

## Code and docs
- Decisions are ADRs in English under `docs/adr/` (new decision = new ADR; a changed decision is superseded by a new ADR, never rewritten).
- PowerShell 7 for reading (Graph, UTCM); Microsoft365DSC runs in its own Windows PowerShell 5.1 process.
- What can only be checked against a real tenant or Windows goes to `validation/` and is run by the user.
- Reuse before building: UTCM, Microsoft365DSC, and MIT-licensed code (with attribution in `THIRD-PARTY.md`). Do not copy code without a license.

## Public-ready
The repository starts private but is built as if public: secret scan in CI, no real data, license MIT.
