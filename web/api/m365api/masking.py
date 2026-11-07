"""Masking of tenant IDs and other GUIDs in every API response (ADR 0009, issue #55).

The core files carry no full Dev tenant ID, but two places keep the full Prod tenant ID because the action
needs it (the cross-tenant partner of the baseline, the protected partner entry of the reset). The API never
shows a full tenant ID or any other GUID: every response passes through mask_response().
"""

from __future__ import annotations

import re
from typing import Any

GUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
TENANT_KEY_RE = re.compile(r"tenantid$", re.IGNORECASE)


def shorten(value: str) -> str:
    """First 8 characters plus '...', as in the audit log; shorter values stay as they are."""
    return value[:8] + "..." if len(value) > 8 else value


def _collect_tenant_values(node: Any, found: set[str]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(value, str) and TENANT_KEY_RE.search(str(key)) and value:
                found.add(value)
        if node.get("Kind") == "Partner" and isinstance(node.get("Name"), str) and node["Name"]:
            # Protected partner entry of the reset: the name is the partner tenant ID.
            found.add(node["Name"])
        for value in node.values():
            _collect_tenant_values(value, found)
    elif isinstance(node, list):
        for item in node:
            _collect_tenant_values(item, found)


def _mask_string(text: str, tenant_values: list[str]) -> str:
    for value in tenant_values:
        if len(value) > 8 and value in text:
            text = text.replace(value, shorten(value))
    return GUID_RE.sub(lambda m: shorten(m.group(0)), text)


def _mask(node: Any, tenant_values: list[str]) -> Any:
    if isinstance(node, dict):
        return {_mask_string(str(k), tenant_values): _mask(v, tenant_values) for k, v in node.items()}
    if isinstance(node, list):
        return [_mask(item, tenant_values) for item in node]
    if isinstance(node, str):
        return _mask_string(node, tenant_values)
    return node


def mask_response(body: Any) -> Any:
    """Returns a masked copy: values of *TenantId keys, partner entries and every GUID are shortened everywhere."""
    found: set[str] = set()
    _collect_tenant_values(body, found)
    # Longest first, so that a value that contains another one is replaced as a whole.
    tenant_values = sorted(found, key=len, reverse=True)
    return _mask(body, tenant_values)
