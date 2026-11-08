"""Read-only Intune backup of one tenant with IntuneCD (issue #68, ADR 0014).

Started by the PowerShell core (Invoke-IntuneBackup) once per tenant, in its own process:

    python intunecd_backup.py --path <empty folder> [--exclude <type> ...] [--include-scripts]

The Graph token of the tenant comes on stdin (one line) and is handed to IntuneCD in memory. It is never put on the
command line (other users could read it in the process list), into an environment variable or into a file. Only the
backup of IntuneCD is called; its update, which writes to a tenant, is never imported.

Fixed choices (see ADR 0014):
* output json, no IDs appended to the file names (files keep their display name, so Git shows a change, not a rename);
* --ignore-omasettings: the plain text of encrypted OMA-URI values is not read (it would be a secret in the files);
* --skip-archive: the core writes into an empty folder and lets Git show what was removed;
* no Entra backup, no Autopilot devices, no activation lock bypass codes, no audit commits.

Exit codes: 0 done, 2 bad call (no token, folder not empty, unknown type), 3 IntuneCD is not installed,
4 the backup failed (message on stderr, without the token).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Callable, Sequence

# Types that change on every read without a change of the configuration, and Conditional Access (outside Intune,
# handled by the toolkit itself, ADR 0003). The operator can add more in config.psd1 (IntuneBackup.Exclude).
DEFAULT_EXCLUDE = ("VPPusedLicenseCount", "GPlaySyncTime", "CompliancePartnerHeartbeat", "ConditionalAccess")
# Script types: their contents may carry secrets, so they are left out unless the operator asks for them
# (--include-scripts, config.psd1 IntuneBackup.IncludeScripts; issue #74, ADR 0015).
SCRIPT_TYPES = ("PowershellScripts", "ShellScripts", "ProactiveRemediation", "ComplianceScripts", "CustomAttributes")
MAX_TOKEN_CHARS = 20000


class CallError(Exception):
    """The wrapper was called wrongly; exit code 2."""


def parse(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only Intune backup of one tenant with IntuneCD (token on stdin).")
    parser.add_argument("--path", required=True, help="Empty folder the backup is written to.")
    parser.add_argument("--exclude", nargs="*", default=[], help="More IntuneCD types to leave out.")
    parser.add_argument("--include-scripts", action="store_true", help="Back up the script types too (left out by default).")
    return parser.parse_args(list(argv))


def read_token(stream: Any) -> str:
    token = stream.readline(MAX_TOKEN_CHARS + 1).strip()
    if not token:
        raise CallError("No token on stdin.")
    if len(token) > MAX_TOKEN_CHARS or any(c.isspace() for c in token):
        raise CallError("The token on stdin is not valid.")
    return token


def intunecd_args(path: Path, exclude: Sequence[str], get_parser: Callable[..., argparse.ArgumentParser],
                  include_scripts: bool = False) -> argparse.Namespace:
    """The arguments of IntuneCD's backup, built with its own parser so an unknown type is refused by IntuneCD."""
    scripts = () if include_scripts else SCRIPT_TYPES
    types = list(dict.fromkeys([*DEFAULT_EXCLUDE, *scripts, *exclude]))
    argv = ["--output", "json", "--path", str(path) + "/", "--mode", "1", "--ignore-omasettings", "--skip-archive",
            "--exclude", *types]
    parser = get_parser(include_help=False)
    try:
        return parser.parse_args(argv)
    except SystemExit as exc:  # argparse exits on an unknown choice
        raise CallError("IntuneCD does not know one of the types to exclude: " + ", ".join(exclude)) from exc


def run(argv: Sequence[str], stdin: Any, start: Callable[[argparse.Namespace], Any] | None = None,
        get_parser: Callable[..., argparse.ArgumentParser] | None = None) -> int:
    try:
        options = parse(argv)
        path = Path(options.path)
        if not path.is_dir():
            raise CallError("The folder does not exist.")
        if any(path.iterdir()):
            raise CallError("The folder is not empty.")
        token = read_token(stdin)
    except CallError as exc:
        print(f"intunecd_backup: {exc}", file=sys.stderr)
        return 2
    if start is None or get_parser is None:
        try:
            from IntuneCD.run_backup import get_parser as cd_parser, start as cd_start  # noqa: PLC0415 - optional at import
        except ImportError:
            print("intunecd_backup: IntuneCD is not installed. Run: pip install --require-hashes -r tools/intunecd/requirements.txt", file=sys.stderr)
            return 3
        start = start or cd_start
        get_parser = get_parser or cd_parser
    try:
        args = intunecd_args(path, options.exclude, get_parser, options.include_scripts)
    except CallError as exc:
        print(f"intunecd_backup: {exc}", file=sys.stderr)
        return 2
    args.token = token  # in memory only; IntuneCD then skips its own sign-in (no token cache file)
    try:
        start(args)
    except BaseException as exc:  # noqa: BLE001 - IntuneCD may raise anything, also SystemExit
        message = str(exc).replace(token, "***")[:300]
        print(f"intunecd_backup: the backup failed: {type(exc).__name__}: {message}", file=sys.stderr)
        return 4
    finally:
        args.token = None
        del token
    return 0


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:], sys.stdin))
