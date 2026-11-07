"""Pure view helpers of the interface (issues #61, #63, #14, #66): time format, next step, order of lists, icons,
the menu by goals and areas, and the forms that start a job.

No FastAPI here: every function takes plain data and is tested on its own. The next step is
derived only from what the read routes of the API already return; nothing is guessed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable
from urllib.parse import urlencode

from markupsafe import Markup

from .i18n import _

ICON_DIR = Path(__file__).resolve().parent / "static" / "icons"
_SVG_RE = re.compile(r'^<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">(<path d="[^"<>]+"/>)</svg>\s*$')

# Name in the templates -> Fluent UI System Icons file (24 px, regular). One place for all icons.
ICON_FILES = {
    "overview": "home", "reports": "document_search", "plans": "clipboard_task_list_ltr", "audit": "history",
    "menu": "navigation", "close": "dismiss", "person": "person", "ok": "checkmark_circle", "warn": "warning",
    "bad": "dismiss_circle", "unknown": "question_circle", "outdated": "arrow_sync", "protected": "shield",
    "next": "arrow_right", "info": "info", "filter": "filter", "clear": "dismiss", "prev-page": "chevron_left",
    "next-page": "chevron_right", "signout": "sign_out", "signin": "door_arrow_left", "back": "arrow_left",
    "entra": "people", "intune": "phone_laptop", "ca": "shield_lock", "step": "lightbulb", "compare": "branch_compare",
    "time": "clock", "todo": "circle",
    "align": "target_arrow", "fresh": "arrow_reset", "fill": "people_add", "jobs": "task_list_ltr", "start": "play",
    "stop": "stop", "running": "arrow_clockwise", "licences": "key", "later": "lock_closed", "delete": "delete",
}


def load_icons(directory: Path = ICON_DIR) -> dict[str, str]:
    """Reads the copied SVG files once. Only a plain single-path SVG is accepted (no script, no attributes)."""
    icons: dict[str, str] = {}
    for name, file in ICON_FILES.items():
        text = (directory / f"{file}_24_regular.svg").read_text(encoding="utf-8")
        m = _SVG_RE.match(text)
        if not m:
            raise ValueError(f"unexpected SVG content in {file}")
        icons[name] = m.group(1)
    return icons


def icon_markup(icons: dict[str, str], name: str, label: str = "") -> Markup:
    """An inline icon. Decorative unless a label is given (then it is read out)."""
    path = icons.get(name)
    if path is None:
        raise KeyError(f"unknown icon {name!r}")
    a11y = f'role="img" aria-label="{Markup.escape(label)}"' if label else 'aria-hidden="true"'
    return Markup(f'<svg class="icon" {a11y} focusable="false" viewBox="0 0 24 24">{path}</svg>')


# ---------------------------------------------------------------- time (#61)

MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def parse_utc(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).astimezone(timezone.utc)


def relative(dt: datetime, now: datetime) -> str:
    seconds = int((now - dt).total_seconds())
    future = seconds < 0
    s = abs(seconds)
    if s < 60:
        return _("just now")
    for size, one, many in ((86400 * 365, _("1 year"), _("{n} years")), (86400 * 30, _("1 month"), _("{n} months")),
                            (86400, _("1 day"), _("{n} days")), (3600, _("1 hour"), _("{n} hours")),
                            (60, _("1 minute"), _("{n} minutes"))):
        if s >= size:
            n = s // size
            text = one if n == 1 else many.format(n=n)
            return _("in {t}").format(t=text) if future else _("{t} ago").format(t=text)
    return _("just now")  # pragma: no cover


@dataclass(frozen=True)
class When:
    iso: str  # exact value as the server sent it, for <time datetime> and the title
    text: str  # readable, in UTC (the browser rewrites it to local time, see app.js)
    rel: str  # relative to now
    ok: bool


def when(value: Any, now: datetime) -> When:
    dt = parse_utc(value)
    if dt is None:
        return When(str(value or ""), str(value or _("unknown")), "", False)
    text = f"{dt.day} {_(MONTHS[dt.month - 1])} {dt.year}, {dt:%H:%M} UTC"
    return When(dt.strftime("%Y-%m-%dT%H:%M:%SZ"), text, relative(dt, now), True)


def time_markup(value: Any, now: datetime) -> Markup:
    """<time> with the exact value in datetime and title; readable text; relative time next to it."""
    w = when(value, now)
    if not w.ok:
        return Markup('<span class="time">{}</span>').format(w.text)
    return Markup('<span class="time"><time datetime="{iso}" title="{iso}" data-local>{text}</time>'
                  ' <span class="rel">({rel})</span></span>').format(iso=w.iso, text=w.text, rel=w.rel)


# ---------------------------------------------------------------- order of lists (#61)

def newest_first(items: Iterable[dict[str, Any]], key: str) -> list[dict[str, Any]]:
    """Newest first; entries in an older format ('outdated') always at the end."""
    def sort_key(item: dict[str, Any]):
        dt = parse_utc(item.get(key)) or datetime.min.replace(tzinfo=timezone.utc)
        return (item.get("state") == "outdated", -dt.timestamp())
    return sorted(items, key=sort_key)


# ---------------------------------------------------------------- audit filters (#13)

# Modes of an audit line as the API knows them, in the order of the work, with a readable name and an icon.
AUDIT_MODES = (
    ("report", "Drift report", "compare"),
    ("plan", "Plan", "plans"),
    ("apply", "Apply", "next"),
    ("refused", "Refused", "bad"),
    ("reset", "Reset", "outdated"),
    ("fitcheck", "Suitability check", "ok"),
)
# Period filter -> days back. Offered as a choice, not typed (docs: guided UX).
AUDIT_PERIODS = (("1d", "Last 24 hours", 1), ("7d", "Last 7 days", 7), ("30d", "Last 30 days", 30))
PLAN_HASH_RE = re.compile(r"^[0-9a-f]{64}$")


def audit_since(period: str, now: datetime) -> str | None:
    """The ``since`` value for the API from a period key; unknown keys mean no limit."""
    for key, _label, days in AUDIT_PERIODS:
        if key == period:
            return (now - timedelta(days=days)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return None


def audit_query(mode: str = "", period: str = "", plan: str = "", page: int = 1) -> str:
    """Query string of the audit page with the filters that are set (for pager and filter links)."""
    pairs = [("mode", mode), ("period", period), ("plan", plan)] + ([("page", str(page))] if page > 1 else [])
    return urlencode([(k, v) for k, v in pairs if v])


def short_hash(value: Any) -> str:
    text = str(value or "")
    return text[:8] + "…" if len(text) > 8 else text


# ---------------------------------------------------------------- next step (#63)

STALE_DAYS = 7  # a drift report older than this counts as old; the next step is to compare again


@dataclass(frozen=True)
class Facts:
    """What the overview knows, taken only from /api/status, /api/fitcheck/latest and /api/plans."""
    has_report: bool
    report_age_days: float | None
    differences: int
    fit_status: str  # green, yellow, red, grey or "" when there is no suitability check
    fit_id: str
    report_id: str
    has_apply_plan: bool


@dataclass(frozen=True)
class Rule:
    id: str
    applies: Callable[[Facts], bool]
    title: str
    detail: str
    command: str = ""
    link: str = ""  # a page of this interface, filled from the facts
    link_text: str = ""
    goal: str = ""  # the goal page where the step is started (issue #66)
    goal_text: str = ""


# The rules as data, first match is the next step; the order is the order of the work.
RULES: tuple[Rule, ...] = (
    Rule("no-report", lambda f: not f.has_report,
         "Run the drift report with the script",
         "There is no comparison of Prod and Dev yet. The report reads both tenants and changes nothing.",
         command="scripts/Get-DriftReport.ps1", goal="/goals/align", goal_text="Compare Prod and Dev"),
    Rule("fit-check", lambda f: f.fit_status in ("red", "grey", ""),
         "Check the suitability report",
         "The suitability check is red, not verified or missing. Find out what Dev cannot mirror before you plan.",
         command="scripts/Invoke-TenantFitCheck.ps1", link="/reports/{fit_id}", link_text="Show the suitability report",
         goal="/goals/align", goal_text="Check the suitability"),
    Rule("stale-report", lambda f: f.report_age_days is not None and f.report_age_days > STALE_DAYS,
         "Compare again",
         "The last comparison is older than {days} days. Run the drift report again so the plan uses the current state.",
         command="scripts/Get-DriftReport.ps1", link="/reports/{report_id}", link_text="Show the last drift report",
         goal="/goals/align", goal_text="Compare again"),
    Rule("differences", lambda f: f.differences > 0,
         "Create a plan",
         "Prod and Dev differ. Create a preview plan; it changes nothing until you confirm it and apply it.",
         command="scripts/Invoke-ApplyDev.ps1", link="/reports/{report_id}", link_text="Show the differences",
         goal="/goals/align", goal_text="Create a plan"),
    Rule("done", lambda f: True,
         "Nothing to do",
         "Prod and Dev match and the last comparison is current.",
         link="/reports/{report_id}", link_text="Show the drift report"),
)


@dataclass(frozen=True)
class Step:
    id: str
    title: str
    detail: str
    command: str
    link: str
    link_text: str
    goal: str = ""
    goal_text: str = ""


def facts(status: dict[str, Any] | None, fit: dict[str, Any] | None, plans: list[dict[str, Any]],
          now: datetime) -> Facts:
    status = status or {}
    last = parse_utc(status.get("lastComparisonUtc"))
    report_id = str(status.get("reportId") or "")
    fit_status = ""
    fit_id = ""
    if fit:
        report = fit.get("report") or {}
        fit_status = str(report.get("Status") or fit.get("status") or "grey").lower()
        if report and report.get("Verified") is False:
            fit_status = "grey"
        fit_id = str(fit.get("id") or "")
    return Facts(
        has_report=bool(report_id and last),
        report_age_days=(now - last).total_seconds() / 86400 if last else None,
        differences=int(status.get("differences") or 0),
        fit_status=fit_status, fit_id=fit_id, report_id=report_id,
        has_apply_plan=any(p.get("kind") == "apply" and p.get("state") != "outdated" for p in plans),
    )


def next_steps(f: Facts) -> list[Step]:
    """All rules that apply, in order; the first one is the next step."""
    out = []
    for r in RULES:
        if r.id == "done" and out:
            break
        if not r.applies(f):
            continue
        link = r.link.format(fit_id=f.fit_id, report_id=f.report_id) if r.link else ""
        if link.endswith("/"):  # no id to link to
            link = ""
        out.append(Step(r.id, _(r.title), _(r.detail).format(days=STALE_DAYS), r.command, link,
                        _(r.link_text) if link else "", r.goal, _(r.goal_text) if r.goal else ""))
    return out


# ---------------------------------------------------------------- resource types (#63)

def type_family(resource_type: Any) -> str:
    """Neutral family of a resource type for its badge: ca, intune, entra or other."""
    t = str(resource_type or "").lower()
    if "conditionalaccess" in t:
        return "ca"
    if "intune" in t or t.startswith(("deviceconfiguration", "devicecompliance", "configurationpolicy",
                                      "assignmentfilter", "deviceenrollment", "mobileapp")):
        return "intune"
    if "entra" in t or t.startswith(("microsoft.graph.", "aad")) or t in ("group", "user", "invitation"):
        return "entra"
    return "other"


# ---------------------------------------------------------------- menu by goals and areas (#66, ADR 0012)

# (key, href, label, icon). Goals start a job; areas configure Dev per product family; history shows what happened.
GOALS = (
    ("align", "/goals/align", "Bring Dev in line", "align"),
    ("fresh", "/goals/fresh", "Start Dev fresh", "fresh"),
    ("fill", "/goals/fill", "Fill Dev", "fill"),
)
# Areas: only Intune is there now (the Intune QA goal); the others are shown greyed out with "later".
AREAS = (
    ("intune", "/areas/intune", "Intune", "intune", True),
    ("entra", "", "Entra ID", "entra", False),
    ("ca", "", "Conditional Access", "ca", False),
    ("licences", "", "Licences", "licences", False),
)
HISTORY = (
    ("jobs", "/jobs", "Jobs", "jobs"),
    ("plans", "/plans", "Plans", "plans"),
    ("reports", "/reports", "Reports", "reports"),
    ("audit", "/audit", "Audit log", "audit"),
)


# ---------------------------------------------------------------- jobs (#14)

JOB_ACTIONS = {
    "drift": "Drift report", "fitcheck": "Suitability check", "plan-apply": "Plan Prod → Dev",
    "plan-baseline": "Base state plan", "plan-users": "Dev users plan", "plan-reset": "Reset plan", "apply": "Apply a plan",
}
ACTIVE_JOB = ("queued", "running")
# The role each goal needs to start its jobs, as the API names it; the API decides, the page only hides buttons
# a person could not use anyway.
APPLY_ROLE = {"apply": "Applier", "baseline": "Applier", "users": "Applier", "reset": "Resetter"}
JOB_ID_RE = re.compile(r"^job-[0-9]{8}-[0-9]{6}-[a-z0-9]{6}$")
FORM_FIELDS = {
    "drift": (), "fitcheck": (), "plan-apply": ("area",), "plan-baseline": (), "plan-users": (),
    "plan-reset": ("mode", "deviceAction"), "apply": ("planId", "confirmPlanHash", "confirmTenant"),
}
CHOICES = {"area": ("All", "Intune"), "mode": ("Align", "Full"), "deviceAction": ("Keep", "Remove", "Retire")}


class FormError(ValueError):
    """The form cannot be sent to the API; the message says what is missing."""


def job_request(form: dict[str, str]) -> dict[str, str]:
    """The body of POST /api/jobs from a form of this interface. Checks only what the form itself must carry (the
    choices offered and the confirmation box of an apply); roles and hashes are checked by the API."""
    action = form.get("action", "")
    if action not in FORM_FIELDS:
        raise FormError(_("Unknown action."))
    body: dict[str, str] = {"action": action}
    for name in FORM_FIELDS[action]:
        value = (form.get(name) or "").strip()
        if not value:
            continue
        if name in CHOICES and value not in CHOICES[name]:
            raise FormError(_("This choice is not offered."))
        body[name] = value
    if action == "apply":
        if form.get("confirmed") != "yes":
            raise FormError(_("Tick the box to confirm that you checked the plan."))
        if not (body.get("planId") and body.get("confirmPlanHash")):
            raise FormError(_("The plan to apply is missing. Open the plan again."))
        if form.get("kind") == "reset" and not body.get("confirmTenant"):
            raise FormError(_("Type the ID of the Dev tenant to confirm the reset."))
    return body


def job_progress(job: dict[str, Any]) -> int:
    """Progress in per cent from the counts the API sends."""
    p = job.get("progress") or {}
    total = int(p.get("total") or 0)
    return 0 if total <= 0 else round(100 * int(p.get("done") or 0) / total)


def latest_plan(items: Iterable[dict[str, Any]], kind: str, area: str | None = None, mode: str | None = None) -> dict[str, Any] | None:
    """The newest current plan of a kind (and area: None = all areas only, or a named area)."""
    for p in newest_first(items, "createdUtc"):
        if p.get("kind") != kind or p.get("state") == "outdated":
            continue
        if (p.get("area") or None) != area:
            continue
        if mode and p.get("mode") != mode:
            continue
        return p
    return None


def area_types(report: dict[str, Any] | None, family: str) -> list[dict[str, Any]]:
    """Per-type rows of a drift report that belong to one area (same families as the badges)."""
    return [t for t in (report or {}).get("Types", []) if type_family(t.get("ResourceType")) == family]
