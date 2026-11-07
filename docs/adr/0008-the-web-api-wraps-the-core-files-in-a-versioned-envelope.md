# 0008. The web API wraps the core files in a versioned envelope

Status: Accepted (2026-11-07, issue #44; follows ADR 0002)

## Context
ADR 0002 couples server and interface only through an OpenAPI description. Before the server and the interface are built in parallel, the data they exchange must be fixed. The core (PowerShell) already writes reports, plans and audit lines under `History/`. These files have no common header: the kind of a plan and its time are only in the file name, and only the suitability check carries a `Schema` field.

## Decision
1. **One schema file** `schema/m365cloning.schema.json` (JSON Schema 2020-12) describes every file the core writes: drift report, plan file (apply, baseline, reset, users), plan summary, licence section, suitability check and audit entry. The fields are the ones the core writes today; the core is not changed for the contract.
2. **The API returns an envelope** around the unchanged core content: `schemaVersion`, `id` (file base name), `kind` (from the file name prefix) and `createdUtc`, plus the core object (`report` or `plan` and `planHash`). Lists return short items with the same header.
3. **`schemaVersion` is `"1"`.** Adding an optional field keeps the version; removing or renaming a field, or changing its meaning, raises it.
4. **`web/openapi.json` (OpenAPI 3.1)** lists the routes. It refers to the schema file; every route has a 200 schema and the `Error` schema for 400 and 500. The first version has read routes only; write routes come with #14.
5. **Contract first:** a new or changed route, or a change of a core file format, comes with its schema, OpenAPI entry, mock example (`web/mock/responses.json`) and contract test (`tests/WebContract.Tests.ps1`) in the same pull request.
6. **No secrets in the contract:** no field may carry a password, token, client secret, certificate or client ID; a test checks the schema, the OpenAPI description, the mock and the files the core writes.

## Consequences
- Server and interface can be built in parallel against the mock.
- The irregularities of the current core files stay visible in the schema (optional keys per plan kind) until a later change makes the core uniform; such a change raises `schemaVersion` if it is breaking.
