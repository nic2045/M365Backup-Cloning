# 0003. Persona groups and naming scheme for Conditional Access and the Dev tenant

Status: Proposed (2026-11-07, personas from the owner's list "Groupings (2025 Active Policies)"; naming scheme is a proposal to confirm)

## Context
Conditional Access (CA) policies are organised by persona. The Dev tenant must carry the same persona logic as Prod, but without Prod users (ADR 0001, ADR 0002). Groups are matched by name, never by ID. Cross-tenant synchronisation brings only test users and administrators (as B2B guests) into the Dev tenant and must place them in the group of their persona.

## Decision
1. **Personas** and their main enforcement focus (input of the owner, not copied from a vendor document; the Microsoft "Conditional Access for Zero Trust" paper is the orientation and is cited in `THIRD-PARTY.md` once the source is added):

| Persona | Main enforcement focus |
|---|---|
| Global (all users) | MFA, block legacy authentication, block non-persona identities, block device code flow |
| Admins | MFA or compliant device, short sessions, block unknown platforms, MFA for device enrollment |
| Internals | MFA baseline, session lifetime by device type, block unknown platforms, compliance and terms of use, restrict unmanaged client apps |
| Externals | MFA baseline, limited sessions, block unknown platforms, terms of use, block enrollment paths |
| Guests | MFA, short session on unmanaged devices |
| Service accounts (Microsoft 365) | Trusted locations only, block other applications |
| BreakGlass | Block sign-ins from untrusted networks; always excluded from every other policy |

2. **Group naming scheme (proposal).** A fixed prefix makes the persona recognisable:
   - Persona membership: `CA-P-<Persona>` (for example `CA-P-Admins`, `CA-P-Internals`, `CA-P-Externals`, `CA-P-Guests`, `CA-P-ServiceAccounts`).
   - Exclusions: `CA-X-<Persona>-<Reason>`; the emergency accounts are `CA-X-BreakGlass`.
   - Policy names start with `CA<nnn>-<Persona>-`. "Global" has no group (all users); it is a policy scope only.
3. **Persona detection** is by this scheme. A group in a CA policy without a recognisable persona is reported, not silently copied.
4. **Dev tenant.** Persona groups are created by name as **static and empty**; dynamic membership rules from Prod are not taken over. Users in Dev are only test users and administrators (administrators as B2B guests through cross-tenant sync), placed in the group of their persona.
5. **Generic.** The scheme contains no customer data. Prefix and persona list live in a local configuration file; the defaults above are only a starting point.

## Consequences
- The apply step (ADR 0001) can create missing persona groups as empty copies and place synchronised users by persona.
- A different prefix or persona set is a configuration change, not a code change.
- The final names are confirmed by the owner; a changed scheme is a new ADR.
