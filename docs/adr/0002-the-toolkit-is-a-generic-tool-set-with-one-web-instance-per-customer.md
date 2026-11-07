# 0002. The toolkit is a generic tool set with one web instance per customer

Status: Accepted (2026-11-07, decided with the owner: own stack, one instance per customer, FastAPI + Jinja2 + HTMX)

## Context
ADR 0001 fixes how the Dev tenant is read, compared and changed. The toolkit also needs a web interface (issue #11) for reports, audit, actions and scenario provisioning. The repository is meant to become public: customers clone it and manage their own environment with it. Wording in ADR 0001 ("per customer there is one pair of a Dev and a Prod tenant") is read as: **each installation manages exactly one pair**.

## Decision
1. **Generic tool set.** The repository holds no customer information, no customer structure and no tenant data. A customer clones it, creates a local `config.psd1` (git-ignored) and runs it for their own environment. This clarifies the context of ADR 0001; the decisions of ADR 0001 stay as they are.
2. **One instance per customer.** An instance has one configuration with one Prod/Dev pair. Configuration, history, reports and audit live in that instance. There is no multi-tenant separation inside an instance.
3. **Own stack, independent of other projects.** Python with FastAPI, Jinja2 templates and HTMX for the web interface; no dependency on SW-Depoyment (no Pode, no shared paths).
4. **Server and interface are coupled only by an OpenAPI description** (`openapi.json`); every route has a contract test. Routes are thin: validate input, call a function, answer.
5. **Actions are jobs in their own process** with a step list and progress (export, report, apply, reset). The state of a job lives in its file, not in server memory. The PowerShell parts are started as child processes: PowerShell 7 for reading (UTCM), Windows PowerShell 5.1 for Microsoft365DSC, exchanging JSON.
6. **Roles and audit.** Local sign-in with the roles Read, Apply and Reset. Every action writes an append-only audit entry (who, what, when, tenant, before/after, no secrets). Apply and Reset need a confirmation in the browser after a preview.
7. **Scenarios are description files** (resources, group scheme, exclusions), not code. The first scenario is "Intune-QA".
8. **No call between the toolkit and other applications.** The shared interface is the tenant itself (Microsoft Graph) and the group naming scheme. A consumer may optionally read a small read-only status (last comparison, number of differences, ok or not) as a file or `GET /api/status`; the toolkit does not know its consumers. Write actions over an API between applications are not planned; if ever needed, they come with an OpenAPI contract, a token per instance and a new ADR.
9. **Hosting.** The instance runs on a Windows host of the customer (Windows PowerShell 5.1 is needed for Microsoft365DSC).

## Consequences
- The public repository stays free of customer data; customers update by pulling.
- A second runtime (Python) and Windows PowerShell 5.1 are needed on the host.
- Order of work: read-only report (#2), then the Dev-tenant functions, then the web interface starting with reporting (#12).
- A changed stack is a new ADR.
- The status format in point 8 is built only when a consumer needs it.
