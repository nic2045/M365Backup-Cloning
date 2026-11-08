"""Reads the files the core writes below History/ (pure functions, no web framework; issue #55).

Layout (written by the PowerShell core, see docs/web-contract.md):
    History/reports/<prefix>-<yyyyMMdd-HHmmss>.json   drift reports, suitability checks, plan files
    History/reports/intune-backup-<yyyyMMdd-HHmmss>.json   what changed in the Intune backup (issue #68)
    History/reports/setup-check-<yyyyMMdd-HHmmss>.json     the setup check of this instance (issue #18)
    History/reports/desired-export-<yyyyMMdd-HHmmss>.json  what changed in the export of the desired state (issue #27)
    History/audit.jsonl                              one audit entry per line, append only
Files in another or an unknown format are refused with 409 in detail and listed as 'outdated' (issue #59).
The store only reads. Ids are file base names; they are checked against a fixed pattern and a known prefix
and the resolved path must stay inside History/reports, so a request can never reach another file.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from . import contract

log = logging.getLogger("m365api")

ID_RE = re.compile(r"^[a-z0-9-]+$")

# Prefix -> (group, kind, mode). Longer prefixes first, so that 'dev-reset-plan-align-' wins over shorter ones.
PREFIXES: list[tuple[str, str, str, str | None]] = [
    ("dev-reset-plan-align-", "plans", "reset", "Align"),
    ("dev-reset-plan-full-", "plans", "reset", "Full"),
    ("dev-baseline-plan-", "plans", "baseline", None),
    ("dev-users-plan-", "plans", "users", None),
    ("apply-plan-", "plans", "apply", None),
    ("tenantfit-", "reports", "tenantfit", None),
    ("drift-", "reports", "drift", None),
    ("intune-backup-", "backups", "intunebackup", None),
    ("desired-export-", "exports", "desiredexport", None),
    ("setup-check-", "setup", "setupcheck", None),
]


class StoreError(Exception):
    """An error that maps to the Error schema: code, message and HTTP status."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Entry:
    id: str
    group: str
    kind: str
    mode: str | None
    path: Path


def classify(file_id: str) -> tuple[str, str, str | None] | None:
    for prefix, group, kind, mode in PREFIXES:
        if file_id.startswith(prefix):
            return group, kind, mode
    return None


def parse_utc(text: str) -> datetime:
    """Parses an ISO 8601 time as the core writes it ('o' format with up to 7 fraction digits, Z or offset)."""
    value = text.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    # Python accepts at most 6 fraction digits; the core writes 7.
    value = re.sub(r"(\.\d{6})\d+", r"\1", value)
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


class Store:
    def __init__(self, history_dir: Path) -> None:
        self.history_dir = Path(history_dir)
        self.reports_dir = self.history_dir / "reports"
        self.audit_file = self.history_dir / "audit.jsonl"

    # --- files -----------------------------------------------------------------------------------------------

    def _entries(self, group: str) -> Iterable[Entry]:
        if not self.reports_dir.is_dir():
            return []
        result = []
        for path in self.reports_dir.glob("*.json"):
            file_id = path.stem
            if not ID_RE.match(file_id):
                continue
            kind_info = classify(file_id)
            if kind_info is None or kind_info[0] != group:
                continue
            result.append(Entry(file_id, kind_info[0], kind_info[1], kind_info[2], path))
        return result

    def _resolve(self, group: str, file_id: str, what: str) -> Entry:
        if not ID_RE.match(file_id or ""):
            raise StoreError(400, "invalid-parameter", "id must contain only a-z, 0-9 and '-'.")
        kind_info = classify(file_id)
        if kind_info is None or kind_info[0] != group:
            raise StoreError(404, "not-found", f"No {what} with this id.")
        reports = self.reports_dir.resolve()
        path = (self.reports_dir / f"{file_id}.json").resolve()
        if path.parent != reports:
            raise StoreError(400, "invalid-parameter", "id must name a file below History/reports.")
        if not path.is_file():
            raise StoreError(404, "not-found", f"No {what} with this id.")
        return Entry(file_id, kind_info[0], kind_info[1], kind_info[2], path)

    @staticmethod
    def _read_json(path: Path) -> Any:
        return json.loads(path.read_text(encoding="utf-8-sig"))

    def _load_checked(self, entry: Entry, definition: str) -> dict[str, Any]:
        """Reads and checks one core file. A file the server cannot open is a server error (500); a file in
        another or an unknown format is a conflict with the stored data (409, issue #59): the cure is to make
        it again with the scripts, so the message says so."""
        try:
            content = self._read_json(entry.path)
        except OSError as exc:
            raise StoreError(500, "unreadable-file", f"The file {entry.id} cannot be read.") from exc
        except ValueError as exc:
            raise StoreError(409, "unsupported-format", f"The file {entry.id} is not valid JSON. Regenerate it with the scripts.") from exc
        if not isinstance(content, dict) or str(content.get("SchemaVersion", "")) != contract.schema_version():
            raise StoreError(409, "unsupported-format", f"The file {entry.id} has an older or unknown format. Regenerate it with the scripts.")
        problems = contract.errors(definition, content)
        if problems:
            log.warning("%s does not match %s: %s", entry.id, definition, problems[:3])
            raise StoreError(409, "unsupported-format", f"The file {entry.id} does not match the format. Regenerate it with the scripts.")
        if str(content.get("Kind", "")) != entry.kind:
            raise StoreError(409, "unsupported-format", f"The file {entry.id} has kind {content.get('Kind')!r}, expected {entry.kind!r}. Regenerate it with the scripts.")
        return content

    @staticmethod
    def _modified_utc(entry: Entry) -> str:
        stamp = datetime.fromtimestamp(entry.path.stat().st_mtime, tz=timezone.utc)
        return stamp.strftime("%Y-%m-%dT%H:%M:%SZ")

    def _load_many(
        self, group: str, definition: str, kind: str | None, include_outdated: bool = False
    ) -> list[tuple[Entry, dict[str, Any] | None, str]]:
        """Entries with their checked content and their time, newest first. With include_outdated, files in
        another format stay in the result with content None and the file time (lists show them as
        'outdated', issue #59); status and the latest check use only current files."""
        loaded: list[tuple[Entry, dict[str, Any] | None, str]] = []
        for entry in self._entries(group):
            if kind and entry.kind != kind:
                continue
            definition_for = definition if group in ("plans", "backups", "exports", "setup") else ("FitCheck" if entry.kind == "tenantfit" else "DriftReport")
            try:
                content = self._load_checked(entry, definition_for)
            except StoreError as exc:
                log.warning("%s in the list is not current: %s", entry.id, exc.message)
                if include_outdated and exc.code == "unsupported-format":
                    loaded.append((entry, None, self._modified_utc(entry)))
                continue
            loaded.append((entry, content, content["CreatedUtc"]))
        # Newest first; files of the same time in id order (as the contract examples).
        loaded.sort(key=lambda item: item[0].id)
        loaded.sort(key=lambda item: parse_utc(item[2]), reverse=True)
        return loaded

    # --- reports ---------------------------------------------------------------------------------------------

    def list_reports(self, kind: str | None) -> dict[str, Any]:
        items = []
        for entry, content, created in self._load_many("reports", "", kind, include_outdated=True):
            item: dict[str, Any] = {"id": entry.id, "kind": entry.kind, "createdUtc": created}
            if content is None:
                item["state"] = "outdated"
            elif entry.kind == "drift":
                item["isIdentical"] = bool(content["IsIdentical"])
                source = content.get("Source")
                item["source"] = "Repository" if isinstance(source, dict) and source.get("Kind") == "Repository" else "Live"
            else:
                item["status"] = content["Status"]
            items.append(item)
        return {"schemaVersion": contract.schema_version(), "items": items}

    def get_report(self, file_id: str) -> dict[str, Any]:
        entry = self._resolve("reports", file_id, "report")
        content = self._load_checked(entry, "FitCheck" if entry.kind == "tenantfit" else "DriftReport")
        return {
            "schemaVersion": contract.schema_version(),
            "id": entry.id,
            "kind": entry.kind,
            "createdUtc": content["CreatedUtc"],
            "report": content,
        }

    def latest_fitcheck(self) -> dict[str, Any]:
        loaded = self._load_many("reports", "", "tenantfit")
        if not loaded:
            raise StoreError(404, "not-found", "No suitability check yet.")
        entry, content, _ = loaded[0]
        return {"schemaVersion": contract.schema_version(), "id": entry.id, "createdUtc": content["CreatedUtc"], "report": content}

    # --- plans -----------------------------------------------------------------------------------------------

    def list_plans(self, kind: str | None) -> dict[str, Any]:
        items = []
        for entry, content, created in self._load_many("plans", "PlanFile", kind, include_outdated=True):
            item: dict[str, Any] = {"id": entry.id, "kind": entry.kind, "createdUtc": created}
            if content is None:
                item["state"] = "outdated"
                if entry.mode:
                    item["mode"] = entry.mode
                items.append(item)
                continue
            item["planHash"] = content["PlanHash"]
            if entry.mode:
                item["mode"] = entry.mode
            if content["Plan"].get("Area"):
                item["area"] = content["Plan"]["Area"]
            item["summary"] = content["Plan"]["Summary"]
            items.append(item)
        return {"schemaVersion": contract.schema_version(), "items": items}

    def get_plan(self, file_id: str) -> dict[str, Any]:
        entry = self._resolve("plans", file_id, "plan")
        content = self._load_checked(entry, "PlanFile")
        return {
            "schemaVersion": contract.schema_version(),
            "id": entry.id,
            "kind": entry.kind,
            "createdUtc": content["CreatedUtc"],
            "planHash": content["PlanHash"],
            "plan": content["Plan"],
        }

    # --- Intune backups (issue #68, ADR 0014) -------------------------------------------------------------------

    def list_backups(self) -> dict[str, Any]:
        items = []
        for entry, content, created in self._load_many("backups", "IntuneBackup", None, include_outdated=True):
            item: dict[str, Any] = {"id": entry.id, "createdUtc": created}
            if content is None:
                item["state"] = "outdated"
            else:
                item["unchanged"] = bool(content["Unchanged"])
                item["commit"] = content["Commit"]
                for key in ("Added", "Changed", "Removed"):
                    item[key.lower()] = sum(int(t[key]) for t in content["Tenants"])
            items.append(item)
        return {"schemaVersion": contract.schema_version(), "items": items}

    def get_backup(self, file_id: str) -> dict[str, Any]:
        entry = self._resolve("backups", file_id, "Intune backup")
        content = self._load_checked(entry, "IntuneBackup")
        return {"schemaVersion": contract.schema_version(), "id": entry.id, "createdUtc": content["CreatedUtc"], "backup": content}

    # --- exports of the desired state (issue #27, ADR 0018) ---------------------------------------------------

    def list_exports(self) -> dict[str, Any]:
        items = []
        for entry, content, created in self._load_many("exports", "DesiredExport", None, include_outdated=True):
            item: dict[str, Any] = {"id": entry.id, "createdUtc": created}
            if content is None:
                item["state"] = "outdated"
            else:
                item["unchanged"] = bool(content["Unchanged"])
                item["commit"] = content["Commit"]
                item["files"] = int(content["Files"])
                for key in ("Added", "Changed", "Removed"):
                    item[key.lower()] = int(content[key])
                item["skipped"] = len(content["Skipped"])
            items.append(item)
        return {"schemaVersion": contract.schema_version(), "items": items}

    def get_export(self, file_id: str) -> dict[str, Any]:
        entry = self._resolve("exports", file_id, "desired state export")
        content = self._load_checked(entry, "DesiredExport")
        return {"schemaVersion": contract.schema_version(), "id": entry.id, "createdUtc": content["CreatedUtc"], "export": content}

    # --- setup check (issue #18) -------------------------------------------------------------------------------

    def latest_setup_check(self) -> dict[str, Any]:
        loaded = self._load_many("setup", "SetupCheck", None)
        if not loaded:
            raise StoreError(404, "not-found", "No setup check yet.")
        entry, content, _ = loaded[0]
        assert content is not None
        return {"schemaVersion": contract.schema_version(), "id": entry.id, "createdUtc": content["CreatedUtc"], "check": content}

    # --- audit -----------------------------------------------------------------------------------------------

    def audit_page(self, mode: str | None, since: datetime | None, page: int, page_size: int,
                   plan_hash: str | None = None) -> dict[str, Any]:
        entries: list[tuple[int, dict[str, Any]]] = []
        if self.audit_file.is_file():
            for number, line in enumerate(self.audit_file.read_text(encoding="utf-8-sig").splitlines()):
                if not line.strip():
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    log.warning("audit line %d is not JSON; skipped", number + 1)
                    continue
                if contract.errors("AuditEntry", entry):
                    log.warning("audit line %d does not match the format; skipped", number + 1)
                    continue
                entries.append((number, entry))
        if mode:
            entries = [e for e in entries if e[1]["Mode"] == mode]
        if since:
            entries = [e for e in entries if parse_utc(e[1]["Timestamp"]) >= since]
        if plan_hash:
            entries = [e for e in entries if e[1]["PlanHash"] == plan_hash]
        # Newest first; equal times keep the reverse file order (the file is append only).
        entries.sort(key=lambda e: (parse_utc(e[1]["Timestamp"]), e[0]), reverse=True)
        start = (page - 1) * page_size
        return {
            "schemaVersion": contract.schema_version(),
            "items": [e[1] for e in entries[start : start + page_size]],
            "page": page,
            "pageSize": page_size,
            "total": len(entries),
        }

    # --- status ----------------------------------------------------------------------------------------------

    def status(self) -> dict[str, Any]:
        drift = self._load_many("reports", "", "drift")
        fit = self._load_many("reports", "", "tenantfit")
        body: dict[str, Any] = {
            "schemaVersion": contract.schema_version(),
            "lastComparisonUtc": None,
            "differences": None,
            "fitStatus": fit[0][1]["Status"] if fit else None,  # type: ignore[index]
            "reportId": None,
        }
        if drift:
            entry, content, _ = drift[0]
            assert content is not None
            summary = content["Summary"]
            body["lastComparisonUtc"] = content["CreatedUtc"]
            body["differences"] = int(summary["Added"]) + int(summary["Removed"]) + int(summary["Changed"])
            body["reportId"] = entry.id
        return body
