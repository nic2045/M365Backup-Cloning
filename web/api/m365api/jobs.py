"""Jobs of the web interface (issue #14, ADR 0012): pure functions and the job files, no web framework.

A job is a file History/jobs/<id>.json (schema JobFile). The API writes it once with status 'queued' and starts the
job runner (scripts/Invoke-WebJob.ps1) in its own process; from then on only the runner writes the file. The API
never runs a script and keeps no job state in memory, so a restart of the server loses nothing.

Rules kept here (and nowhere in the interface):
* which role an action needs (from src/M365Cloning/Data/WebJobs.json, the same table the runner uses);
* one job at a time: a queued or running job blocks the next one (409), unless it has shown no sign of life for
  a while (then it counts as stopped);
* the confirmation of an apply: the plan hash the person looked at must be the hash of the plan file now; a reset
  plan also needs the Dev tenant ID typed by the person. Only its SHA-256 is stored; the runner compares it with the
  plan and the config. The runner checks everything again before the script runs, and the script checks the hash
  once more against the tenants as they are then.
* cancel: a marker file History/jobs/<id>.cancel; the runner stops before its next step.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import secrets
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

from . import contract
from .store import StoreError, parse_utc

log = logging.getLogger("m365api.jobs")

DEFINITIONS_PATH = contract.REPO_ROOT / "src" / "M365Cloning" / "Data" / "WebJobs.json"
RUNNER_SCRIPT = contract.REPO_ROOT / "scripts" / "Invoke-WebJob.ps1"
JOB_ID_RE = re.compile(r"^job-[0-9]{8}-[0-9]{6}-[a-z0-9]{6}$")
ACTIVE = ("queued", "running")
# No sign of life for this long: the job counts as stopped (it no longer blocks and is shown as failed).
QUEUED_TIMEOUT = timedelta(minutes=10)
RUNNING_TIMEOUT = timedelta(hours=6)
MAX_LIST = 50
LOG_LINES = 200
LOG_LINE_CHARS = 500
MAX_BODY_BYTES = 4096

PWSH_ENV = "M365CLONING_PWSH"
CONFIG_ENV = "M365CLONING_CONFIG"


def definitions() -> dict[str, Any]:
    return json.loads(DEFINITIONS_PATH.read_text(encoding="utf-8-sig"))


def utc_text(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tenant_hash(typed: str) -> str:
    """SHA-256 of a tenant ID as the core computes it (Get-TenantIdHash): trimmed, lower case."""
    return hashlib.sha256(typed.strip().lower().encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class JobRequest:
    action: str
    area: str | None = None
    mode: str | None = None
    device_action: str | None = None
    plan_id: str | None = None
    confirm_plan_hash: str | None = None
    confirm_tenant: str | None = None
    scope: str | None = None


# Which fields belong to which action; anything else is refused, so a request never carries more than it means.
FIELDS_OF = {
    "drift": set(),
    "fitcheck": set(),
    "intune-backup": set(),
    "setup-check": {"scope"},
    "plan-apply": {"area"},
    "plan-baseline": set(),
    "plan-users": set(),
    "plan-reset": {"mode", "deviceAction"},
    "apply": {"planId", "confirmPlanHash", "confirmTenant"},
}


def parse_request(body: Any) -> JobRequest:
    """Checks the body of POST /api/jobs (schema JobRequest plus the fields of its action)."""
    problems = contract.errors("JobRequest", body)
    if problems:
        raise StoreError(400, "invalid-parameter", "The request is not valid: " + problems[0][:200])
    action = body["action"]
    extra = set(body) - {"action"} - FIELDS_OF[action]
    if extra:
        raise StoreError(400, "invalid-parameter", f"{', '.join(sorted(extra))} does not belong to the action {action}.")
    if action == "apply" and not (body.get("planId") and body.get("confirmPlanHash")):
        raise StoreError(400, "invalid-parameter", "apply needs planId and confirmPlanHash (the hash of the plan you looked at).")
    return JobRequest(action, body.get("area"), body.get("mode"), body.get("deviceAction"), body.get("planId"),
                      body.get("confirmPlanHash"), body.get("confirmTenant"), body.get("scope"))


def role_for(action: str, plan_kind: str | None = None, table: dict[str, Any] | None = None,
             scope: str | None = None) -> str:
    """The role an action needs: from the job table; apply depends on the kind of the plan, the setup check on its
    scope (issue #76: the config-only check signs in nowhere, so a Reader may start it; roleByScope in the table)."""
    entry = (table or definitions())["actions"][action]
    if action == "apply":
        by_kind = entry["byPlanKind"].get(plan_kind or "")
        if by_kind is None:
            raise StoreError(400, "invalid-parameter", "This plan kind cannot be applied.")
        return str(by_kind["role"])
    by_scope = entry.get("roleByScope") or {}
    if scope and scope in by_scope:
        return str(by_scope[scope])
    return str(entry["role"])


def check_apply(request: JobRequest, plan: dict[str, Any]) -> str:
    """First (and for a reset second) confirmation against the plan as the API reads it now. Returns the plan kind."""
    if request.confirm_plan_hash != plan.get("planHash"):
        raise StoreError(409, "plan-changed", "The plan hash does not match this plan. Open the plan again and confirm what you see.")
    kind = str(plan.get("kind"))
    if kind == "reset":
        if not (request.confirm_tenant or "").strip():
            raise StoreError(400, "invalid-parameter", "A reset needs the Dev tenant ID typed as the second confirmation.")
        if tenant_hash(request.confirm_tenant or "") != plan.get("plan", {}).get("TargetTenantHash"):
            raise StoreError(409, "tenant-mismatch", "The tenant ID you typed is not the Dev tenant of this plan.")
    elif request.confirm_tenant:
        raise StoreError(400, "invalid-parameter", "confirmTenant belongs to a reset plan only.")
    return kind


Launcher = Callable[[Path, Path], None]


def default_launcher(history_dir: Path) -> Launcher:
    """Starts the job runner in its own process (PowerShell 7) and returns at once."""

    def launch(job_path: Path, out_path: Path) -> None:
        cmd = [os.environ.get(PWSH_ENV, "pwsh"), "-NoProfile", "-NonInteractive", "-File", str(RUNNER_SCRIPT),
               "-JobPath", str(job_path), "-HistoryRoot", str(history_dir)]
        config = os.environ.get(CONFIG_ENV, "").strip()
        if config:
            cmd += ["-ConfigPath", config]
        kwargs: dict[str, Any] = {"stdin": subprocess.DEVNULL, "close_fds": True}
        if sys.platform == "win32":
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS  # type: ignore[attr-defined]
        else:
            kwargs["start_new_session"] = True
        with open(out_path, "ab") as out:
            subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, **kwargs)  # noqa: S603 - fixed command, no shell

    return launch


class JobStore:
    def __init__(self, history_dir: Path, launcher: Launcher | None = None,
                 clock: Callable[[], datetime] | None = None) -> None:
        self.history_dir = Path(history_dir)
        self.jobs_dir = self.history_dir / "jobs"
        self.launcher = launcher or default_launcher(self.history_dir)
        self.clock = clock or (lambda: datetime.now(timezone.utc))

    # --- files ------------------------------------------------------------------------------------------------

    def _path(self, job_id: str, suffix: str = ".json") -> Path:
        if not JOB_ID_RE.fullmatch(job_id or ""):
            raise StoreError(400, "invalid-parameter", "The job id is not valid.")
        return self.jobs_dir / f"{job_id}{suffix}"

    def _read(self, path: Path) -> dict[str, Any] | None:
        try:
            content = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            log.warning("job file %s cannot be read", path.name)
            return None
        problems = contract.errors("JobFile", content)
        if problems:
            log.warning("job file %s does not match the format: %s", path.name, problems[:3])
            return None
        return content

    def _write(self, path: Path, content: dict[str, Any]) -> None:
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(content, indent=2), encoding="utf-8")
        os.replace(tmp, path)

    def _log(self, job_id: str) -> list[str]:
        lines: list[str] = []
        for suffix in (".log", ".out"):
            path = self._path(job_id, suffix)
            if path.is_file():
                try:
                    lines += path.read_text(encoding="utf-8-sig", errors="replace").splitlines()
                except OSError:
                    continue
        return [line[:LOG_LINE_CHARS] for line in lines if line.strip()][-LOG_LINES:]

    # --- views ------------------------------------------------------------------------------------------------

    def _stale(self, job: dict[str, Any]) -> bool:
        if job["status"] not in ACTIVE:
            return False
        try:
            updated = parse_utc(job["updatedUtc"])
        except ValueError:
            return True
        limit = QUEUED_TIMEOUT if job["status"] == "queued" else RUNNING_TIMEOUT
        return self.clock() - updated > limit

    def _view(self, content: dict[str, Any], with_log: bool) -> dict[str, Any]:
        job = dict(content["Job"])
        if self._stale(job):
            job["status"] = "failed"
            job["message"] = "The job runner has shown no sign of life for too long and has probably stopped. See the log."
        steps = job["steps"]
        total = len(steps) or len(definitions()["steps"])
        body: dict[str, Any] = {"schemaVersion": contract.schema_version(), **job,
                                "cancelRequested": self._path(job["id"], ".cancel").is_file(),
                                "progress": {"done": sum(1 for s in steps if s["status"] in ("done", "skipped")), "total": total}}
        if with_log:
            body["log"] = self._log(job["id"])
        return body

    def list_jobs(self) -> dict[str, Any]:
        items = []
        if self.jobs_dir.is_dir():
            for path in self.jobs_dir.glob("job-*.json"):
                if not JOB_ID_RE.fullmatch(path.stem):
                    continue
                content = self._read(path)
                if content is not None:
                    items.append(self._view(content, with_log=False))
        items.sort(key=lambda j: (j["createdUtc"], j["id"]), reverse=True)
        return {"schemaVersion": contract.schema_version(), "items": items[:MAX_LIST]}

    def get_job(self, job_id: str) -> dict[str, Any]:
        path = self._path(job_id)
        if not path.is_file():
            raise StoreError(404, "not-found", "No job with this id.")
        content = self._read(path)
        if content is None:
            raise StoreError(409, "unsupported-format", f"The job file {job_id} does not match the format.")
        return self._view(content, with_log=True)

    def active_job(self) -> dict[str, Any] | None:
        for job in self.list_jobs()["items"]:
            if job["status"] in ACTIVE:
                return job
        return None

    # --- changes ----------------------------------------------------------------------------------------------

    def create(self, request: JobRequest, role: str, actor: str, plan: dict[str, Any] | None = None) -> dict[str, Any]:
        """Writes the queued job and starts the runner. One job at a time (409 job-running)."""
        running = self.active_job()
        if running is not None:
            raise StoreError(409, "job-running", f"Another job is still {running['status']} ({running['id']}). Wait for it or cancel it.")
        now = self.clock()
        job_id = f"job-{now.astimezone(timezone.utc):%Y%m%d-%H%M%S}-{''.join(secrets.choice('abcdefghijklmnopqrstuvwxyz0123456789') for _ in range(6))}"
        options: dict[str, Any] = {}
        if request.action == "plan-apply":
            options["area"] = request.area or "All"
        if request.action == "setup-check":
            options["scope"] = request.scope or "All"
        if request.action == "plan-reset":
            options["mode"] = request.mode or "Align"
            options["deviceAction"] = request.device_action or "Keep"
        confirm: dict[str, str] = {}
        if request.action == "apply" and plan is not None:
            options.update({"planId": plan["id"], "planKind": plan["kind"], "planHash": plan["planHash"]})
            confirm["PlanHash"] = plan["planHash"]
            if plan["kind"] == "reset":
                confirm["TenantHash"] = tenant_hash(request.confirm_tenant or "")
        stamp = utc_text(now)
        content = {
            "SchemaVersion": contract.schema_version(),
            "Kind": "job",
            "Job": {
                "id": job_id, "action": request.action, "status": "queued", "role": role, "actor": actor[:256],
                "createdUtc": stamp, "updatedUtc": stamp, "startedUtc": None, "finishedUtc": None,
                "options": options, "steps": [], "message": "Waiting for the job runner.", "result": {},
            },
            "Confirm": confirm,
        }
        problems = contract.errors("JobFile", content)
        if problems:  # pragma: no cover - guarded by the request schema
            raise StoreError(500, "invalid-job", "The job could not be written.")
        path = self._path(job_id)
        self._write(path, content)
        try:
            self.launcher(path, self._path(job_id, ".out"))
        except OSError as exc:
            log.error("job runner could not be started: %s", type(exc).__name__)
            content["Job"].update({"status": "failed", "finishedUtc": stamp,
                                   "message": "The job runner could not be started. Is PowerShell 7 (pwsh) installed? Set M365CLONING_PWSH to its path."})
            self._write(path, content)
            raise StoreError(500, "job-start-failed", content["Job"]["message"]) from exc
        return self._view(content, with_log=False)

    def role_of(self, job_id: str) -> str:
        return str(self.get_job(job_id)["role"])

    def cancel(self, job_id: str) -> dict[str, Any]:
        job = self.get_job(job_id)
        if job["status"] not in ACTIVE:
            raise StoreError(409, "job-finished", f"The job is {job['status']}; there is nothing to cancel.")
        self._path(job_id, ".cancel").write_text(utc_text(self.clock()) + "\n", encoding="utf-8")
        return self.get_job(job_id)
