# Architecture decisions

| ADR | Title | Status |
|---|---|---|
| [0001](0001-the-dev-tenant-stack-reads-with-utcm-and-applies-with-microsoft365dsc-to-dev-only.md) | The Dev tenant stack reads with UTCM and applies with Microsoft365DSC to Dev only | Accepted |
| [0002](0002-the-toolkit-is-a-generic-tool-set-with-one-web-instance-per-customer.md) | The toolkit is a generic tool set with one web instance per customer (own stack, OpenAPI, jobs in own process, roles and audit, no call between applications) | Accepted |
| [0003](0003-persona-groups-and-naming-scheme-for-conditional-access-and-the-dev-tenant.md) | Persona groups and naming scheme for Conditional Access and the Dev tenant (static empty copies, test users and admins only; follows the Microsoft Zero Trust CA paper) | Proposed |
| [0004](0004-the-desired-state-lives-as-code-in-a-private-configuration-repository-of-the-operator.md) | The desired state lives as code in a private configuration repository of the operator (Prod export to files, Dev built only from it, drift as report, no write path to Prod) | Accepted |
| [0005](0005-the-factory-reset-is-the-one-deleting-run-align-by-default-full-on-purpose.md) | The factory reset is the one deleting run: Align (only Dev-only objects) by default, Full on purpose; protection list incl. Prod Global Administrators, two confirmations, Graph allow list, controlled rebuild | Accepted; devices "listed only" superseded in part by 0007 |
| [0006](0006-everything-is-copied-unless-it-is-on-the-exclusion-list.md) | Everything is copied unless it is on the exclusion list (generic handling, exclusion list as data, special handling only for safety) | Accepted |
| [0007](0007-devices-in-the-reset-are-kept-unless-an-action-is-chosen.md) | Devices in the reset are kept unless an action is chosen (Keep, Remove, Retire; Wipe only with Dev.AllowDeviceWipe; protected prefixes and users; device actions last) | Accepted |
| [0008](0008-the-web-api-wraps-the-core-files-in-a-versioned-envelope.md) | The web API wraps the core files in a versioned envelope (one schema file, OpenAPI 3.1 read routes, contract first, no secrets) | Accepted |
