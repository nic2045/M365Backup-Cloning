# 0004. The desired state lives as code in a private configuration repository of the operator

Status: Accepted (2026-11-07, decided with the owner in issue #27: source of truth A, no write path to Prod)

## Context
The toolkit builds and resets the Dev tenant and keeps it close to Prod (ADR 0001). So far the desired state is a Prod snapshot read at run time plus local files (configuration, baseline, user list). Environments should be built cleanly and repeatably, every change should be traceable and approved, and drift should be visible. The toolkit repository itself holds no customer data (ADR 0002).

## Decision
1. **Source of truth is a configuration repository.** The desired state of an installation lives as files in a separate, private Git repository of the operator (not in this repository). The toolkit is given its path in the local configuration.
2. **Format.** One normalised file per resource, grouped by workload and resource type, named by display name. IDs, timestamps and other tenant-specific values are removed; group, filter and persona references are kept by name (ADR 0003). Profiles that carry secrets are not written (ADR 0001 rules).
3. **Export from Prod writes the files.** A read-only export turns a Prod snapshot into these files. The operator takes changes over by a commit or pull request in the configuration repository; the Git history is the change log and the review is the approval.
4. **Dev is built only from the configuration repository.** Baseline (#8), apply (Intune, Conditional Access, groups) and users (#22) read their desired state from it. The reset (#7) returns Dev to this state. Plan, plan hash, confirmation and audit stay as they are.
5. **Sync is a report first.** A drift report compares the configuration repository with Dev, and the latest Prod export with the configuration repository. Applying stays a confirmed action; a schedule may only produce reports.
6. **No write path to Prod.** The toolkit never writes to Prod; Prod is read for the export only (unchanged from ADR 0001). A later write path would need a new ADR with a four-eyes rule.
7. **Out of the configuration repository:** apps and their content (SW-Depoyment), secrets and certificates (local secret store), audit and history (local `History\`).

## Consequences
- The local configuration gains the path to the configuration repository; existing local files (baseline, user list) move there over time.
- The export becomes a separate step whose output is reviewed before anything reaches Dev.
- Tests use invented configuration repositories as fixtures; no real data.
- Implementing the export to files and reading from the repository follows in separate pull requests (issue #27).
