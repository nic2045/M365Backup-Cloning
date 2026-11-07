"""Validation of every response against schema/m365cloning.schema.json (ADR 0008, ADR 0009)."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_PATH = REPO_ROOT / "schema" / "m365cloning.schema.json"
OPENAPI_PATH = REPO_ROOT / "web" / "openapi.json"


@lru_cache(maxsize=1)
def _schema() -> dict[str, Any]:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8-sig"))


@lru_cache(maxsize=None)
def validator(definition: str) -> Draft202012Validator:
    schema = _schema()
    registry = Registry().with_resource(schema["$id"], Resource.from_contents(schema))
    return Draft202012Validator({"$ref": f"{schema['$id']}#/$defs/{definition}"}, registry=registry)


def errors(definition: str, instance: Any) -> list[str]:
    """Schema errors of the instance against $defs/<definition>; empty when valid."""
    return [f"{'/'.join(map(str, e.absolute_path)) or '(root)'}: {e.message}" for e in validator(definition).iter_errors(instance)]


def schema_version() -> str:
    return str(_schema()["$defs"]["SchemaVersion"]["const"])


def enum_values(definition: str) -> list[str]:
    return list(_schema()["$defs"][definition]["enum"])


def audit_modes() -> list[str]:
    return list(_schema()["$defs"]["AuditEntry"]["properties"]["Mode"]["enum"])
