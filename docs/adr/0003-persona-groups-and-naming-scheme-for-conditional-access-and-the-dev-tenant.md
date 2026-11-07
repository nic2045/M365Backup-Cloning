# 0003. Persona groups and naming scheme for Conditional Access and the Dev tenant

Status: Proposed (2026-11-07, personas from the owner's list "Groupings (2025 Active Policies)"; naming follows the Microsoft paper below as the owner asked; to be confirmed by the owner)

## Context
Conditional Access (CA) policies are organised by persona. The Dev tenant must carry the same persona logic as Prod, but without Prod users (ADR 0001, ADR 0002). Groups are matched by name, never by ID. Cross-tenant synchronisation brings only test users and administrators (as B2B guests) into the Dev tenant and must place them in the group of their persona.

Orientation: Microsoft, "Conditional Access Governance and Principles for Zero Trust" (October 2023, repository `microsoft/ConditionalAccessforZeroTrustResources`). It is cited, not copied; see `THIRD-PARTY.md`.

## Decision
1. **Personas.** The active set is the owner's list; the paper's further personas can be switched on in the local configuration.

| Persona | Group | Policy numbers | Main enforcement focus |
|---|---|---|---|
| Global | none (placeholder for all-user policies) | CA001-CA099 | MFA, block legacy authentication, block identities that belong to no persona, block device code flow |
| Admins | `CA-Persona-Admins` | CA100-CA199 | MFA or compliant device, short sessions, block unknown platforms, MFA for device enrollment |
| Internals | `CA-Persona-Internals` | CA200-CA299 | MFA baseline, session lifetime by device type, block unknown platforms, compliance and terms of use, restrict unmanaged client apps |
| Externals | `CA-Persona-Externals` | CA300-CA399 | MFA baseline, limited sessions, block unknown platforms, terms of use, block enrollment paths |
| Guests | `CA-Persona-Guests` | CA400-CA499 | MFA, short session on unmanaged devices |
| Microsoft365ServiceAccounts | `CA-Persona-Microsoft365ServiceAccounts` | CA600-CA699 | Trusted locations only, block other applications |
| BreakGlass | `CA-BreakglassAccounts` | none | Excluded from all other policies; its own policy blocks sign-ins from untrusted networks |

   Further personas from the paper, off by default: GuestAdmins (CA500-CA599), AzureServiceAccounts (CA700-CA799), CorpServiceAccounts (CA800-CA899), WorkloadIdentities (CA900-CA999), Developers (CA1000-CA1099).

2. **Policy names** follow the paper: `<CAnumber>-<Persona>-<PolicyType>-<App>-<Platform>-<Grant>-<OptionalDescription>`. Policy types: BaseProtection, IdentityProtection, DataProtection, AppProtection, AttackSurfaceReduction, Compliance. The number ranges above keep new personas addable without renumbering.
3. **Exclusion groups** are security groups: `CA-Persona-<Persona>-<PolicyType>-Exclusions` for temporary exclusions (normally empty) and the emergency group `CA-BreakglassAccounts`, excluded from every policy. Static exclusions are direct exclusions in the policy.
4. **Persona detection** is by this scheme. A group in a CA policy without a recognisable persona is reported, not silently copied.
5. **Dev tenant.** Persona and exclusion groups are created by name as **static and empty**; dynamic membership rules (including the paper's ring groups `...-Ring0..3`) from Prod are not taken over. Users in Dev are only test users and administrators (administrators as B2B guests through cross-tenant sync), each in the group of their persona. New policies arrive in Report-only.
6. **Generic.** Prefix, persona list and numbers are configuration with the defaults above; the repository holds no customer data.

## Consequences
- The apply step (ADR 0001) can create missing persona and exclusion groups as empty copies and place synchronised users by persona.
- A different prefix or persona set is a configuration change, not a code change.
- A changed scheme is a new ADR.
