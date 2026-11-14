# 0022. The gate is the local run; GitHub Actions only by hand

Status: Accepted (2026-11-14, owner in chat: there is no more budget for GitHub Actions, either wait for the new month or test locally). Changes "secret scan in CI" of the working rules.

## Context
The account has no budget for GitHub Actions minutes. The four workflows (`ci` with Pester on Windows and the secret scan, `ci-api`, `ci-ui`, `ci-intunecd`) ran on every pull request and every push to `main`.

## Decision
1. **All four workflows run only by hand** (`workflow_dispatch`, Actions > Run workflow): nothing starts on a pull request or a push.
2. **The gate is the local run**: `pwsh scripts/Test-Local.ps1` (Pester, pytest of `web/api`, `web/ui` and `tools/intunecd`, gitleaks). A step whose tool is missing is skipped and said so. The text of the pull request says what ran (command, result) and what stayed unchecked.
3. **The secret scan** is gitleaks on the owner's machine (the script) and, when budget is there, `ci` by hand. A leak found later is fixed as before (`.gitleaksignore` only for proven false positives); the repository stays "built as if public": no real data in it.
4. A red or not started Actions run is no finding about the code.

## Consequences
- No minutes are spent; the checks depend on the machine that runs them.
- Claude runs what its environment has (the Python suites) and names the rest as unchecked until PowerShell 7 and Pester are set up there.
