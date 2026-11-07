"""Password hash of the local account (issue #60, ADR 0010).

scrypt from the standard library (hashlib.scrypt): memory-hard, no extra dependency, and the parameters
travel in the stored string so they can be raised later. Format:
``scrypt$<n>$<r>$<p>$<salt base64>$<hash base64>``. Comparison in constant time (hmac.compare_digest).

Make a hash (it is printed, never stored by this tool; put it in your secret store or the environment
variable M365_UI_LOCAL_PASSWORD_HASH, never in the repository):

    python -m m365ui.passwords
"""

from __future__ import annotations

import base64
import getpass
import hashlib
import hmac
import secrets
import sys

N, R, P = 2**15, 8, 1
KEY_LEN = 32
MAXMEM = 128 * 1024 * 1024
MIN_LENGTH = 12


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _derive(password: str, salt: bytes, n: int, r: int, p: int, length: int) -> bytes:
    return hashlib.scrypt(password.encode("utf-8"), salt=salt, n=n, r=r, p=p, dklen=length, maxmem=MAXMEM)


def hash_password(password: str) -> str:
    if len(password) < MIN_LENGTH:
        raise ValueError(f"The password needs at least {MIN_LENGTH} characters.")
    salt = secrets.token_bytes(16)
    return f"scrypt${N}${R}${P}${_b64(salt)}${_b64(_derive(password, salt, N, R, P, KEY_LEN))}"


def _parse(stored: str) -> tuple[int, int, int, bytes, bytes] | None:
    try:
        kind, n, r, p, salt, digest = stored.split("$")
        if kind != "scrypt":
            return None
        n_, r_, p_ = int(n), int(r), int(p)
        if not (2**14 <= n_ <= 2**20 and 1 <= r_ <= 32 and 1 <= p_ <= 16):
            return None
        return n_, r_, p_, base64.b64decode(salt, validate=True), base64.b64decode(digest, validate=True)
    except (ValueError, TypeError):
        return None


def is_valid_hash(stored: str) -> bool:
    return _parse(stored) is not None


# Used when the user name is unknown, so a wrong name costs the same time as a wrong password.
_DUMMY = f"scrypt${N}${R}${P}${_b64(b'0' * 16)}${_b64(b'0' * KEY_LEN)}"


def verify_password(password: str, stored: str | None) -> bool:
    parsed = _parse(stored or "") or _parse(_DUMMY)
    assert parsed is not None
    n, r, p, salt, digest = parsed
    candidate = _derive(password, salt, n, r, p, len(digest))
    return hmac.compare_digest(candidate, digest) and stored is not None and _parse(stored) is not None


def main() -> int:  # pragma: no cover - interactive
    first = getpass.getpass("New password for the local account: ")
    if first != getpass.getpass("Repeat: "):
        print("The passwords differ.", file=sys.stderr)
        return 1
    try:
        print(hash_password(first))
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
