# 0016. The web app starts with one command, and the local account is a break-glass account for management only

Status: Accepted (2026-11-08, issue #79). Supersedes point 4 of ADR 0010 in one respect: the role of the local account.

## Context
Using the web app against real data took two Python environments, two processes and about 13 environment variables set
by hand. The local account of ADR 0010 could hold any role, so it could also start reports, apply and reset. The owner
decided that the local account is a break-glass account: it exists for when Entra ID sign-in is not possible, for
managing the app, not for the normal work.

## Decision
1. **One command.** `scripts/Start-M365CloningWeb.ps1` (PowerShell 7) checks Python 3.12 (the version the lock files are
   compiled for), creates one environment per app under `web.local\` and installs `requirements.txt` with
   `--require-hashes`, starts the API and the interface on `127.0.0.1` only, waits until both answer, opens the browser
   and stops both on Ctrl+C. `-Check` only checks and creates nothing.
2. **Settings in one file.** `web.settings.psd1` (git-ignored; template `web.settings.example.psd1`) holds the Entra IDs,
   the break-glass account and the ports. The script gives the values only to the two child processes as environment
   variables; it does not change its own session and prints no secret, hash or ID. A missing or wrong value stops the
   start with the field, the problem and what to do.
3. **No secret in the settings file.** The shared token secret of ADR 0010 point 5 is made once (32 random bytes) and kept
   in `web.local\token.secret`, readable only by the current user. The interface is registered as a desktop app and needs
   no client secret. The password of the break-glass account is asked for once (`-SetLocalPassword`); only its scrypt hash
   is written into the settings file.
4. **Break-glass account: role Reader only.** The local account reads everything and may run the setup check of the
   configuration (role Reader, ADR 0012 / issue #76). Reports, apply, reset and the Intune backup need an Entra ID
   sign-in with an app role. This is enforced three times: the start script refuses `Role` other than `Reader`, the
   interface refuses `M365_UI_LOCAL_ROLE` other than `Reader` (local sign-in stays off, with an error in its log), and the
   API gives a local token at most `Reader`, whatever roles it carries. The interface shows "Break-glass account:
   management only" on every page of a local session.
5. **Entra ID is the normal way in.** The admin registers the two apps and assigns the app roles by following
   `docs/getting-started.md`; the toolkit writes nothing into a tenant for this.

## Consequences
- An instance without Entra ID settings can be managed (read, setup check) but not used for changes. That is wanted.
- `M365_UI_LOCAL_ROLE=Applier` or `Resetter` from an earlier setup stops working; the local account signs in only after
  it is set to `Reader`.
- The start script is for one admin machine (ADR 0002). A hosted instance (reverse proxy, TLS, service) is not covered.
