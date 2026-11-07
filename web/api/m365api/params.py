"""Checks and converts query parameters (pure functions, no web framework; issue #55)."""

from __future__ import annotations

import re
from datetime import datetime

from . import contract
from .store import StoreError, parse_utc


def optional_enum(name: str, value: str | None, definition: str) -> str | None:
    if value is None or value == "":
        return None
    allowed = contract.enum_values(definition)
    if value not in allowed:
        raise StoreError(400, "invalid-parameter", f"{name} must be one of: {', '.join(allowed)}.")
    return value


def audit_mode(value: str | None) -> str | None:
    if value is None or value == "":
        return None
    allowed = contract.audit_modes()
    if value not in allowed:
        raise StoreError(400, "invalid-parameter", f"mode must be one of: {', '.join(allowed)}.")
    return value


def since(value: str | None) -> datetime | None:
    if value is None or value == "":
        return None
    try:
        return parse_utc(value)
    except ValueError as exc:
        raise StoreError(400, "invalid-parameter", "since must be a date and time in ISO 8601 (for example 2026-11-07T12:00:00Z).") from exc


PLAN_HASH_RE = re.compile(r"^[0-9a-f]{64}$")


def plan_hash(value: str | None) -> str | None:
    """The SHA-256 plan hash as the core writes it (issue #13): 64 lowercase hex characters."""
    if value is None or value == "":
        return None
    if not PLAN_HASH_RE.fullmatch(value):
        raise StoreError(400, "invalid-parameter", "planHash must be 64 lowercase hex characters (the plan hash).")
    return value


def bounded_int(name: str, value: str | None, default: int, minimum: int, maximum: int | None) -> int:
    if value is None or value == "":
        return default
    try:
        number = int(value)
    except ValueError as exc:
        raise StoreError(400, "invalid-parameter", f"{name} must be a whole number.") from exc
    if number < minimum or (maximum is not None and number > maximum):
        if maximum is None:
            raise StoreError(400, "invalid-parameter", f"{name} must be {minimum} or more.")
        raise StoreError(400, "invalid-parameter", f"{name} must be between {minimum} and {maximum}.")
    return number
