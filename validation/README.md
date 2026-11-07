# Validation (run by the owner, not by Claude)

Everything here needs a real tenant. The unit tests (`tests/`) use mocks only. Nothing in this folder is run automatically. Drift report (issue #2 part 1) and apply to Dev (issue #2 part 2), ADR 0001.

## Before the first run

| # | Check | How | Expected |
|---|---|---|---|
| 1 | UTCM service principal exists in **both** tenants | Follow Learn: *Set up authentication for Tenant Configuration Management APIs* (`utcm-authentication-setup`) | Service principal with the UTCM app id present |
| 2 | UTCM has read permissions for the resource types | Grant per resource type as listed on Learn (`utcm-intune-resources`, `utcm-entra-resources`) | Snapshot does not end `failed` or `partiallySuccessful` because of permissions |
| 3 | App registration per tenant with certificate | Prod: read-only. Dev: its own registration. Permission for the snapshot call: `ConfigurationMonitoring.ReadWrite.All` (the only one Learn lists for `createSnapshot`) | App-only token (scope `https://graph.microsoft.com/.default`) works |
| 4 | Licence / availability of the API in the tenant | `GET /v1.0/admin/configurationManagement/configurationSnapshotJobs` with the token | `200`, not `403`/`404` |

Note: `ConfigurationMonitoring.ReadWrite.All` is a write-named permission. The tool only ever sends `POST .../configurationSnapshots/createSnapshot` (guard in `Invoke-UtcmGraphRequest`, covered by tests) and GET requests. If you want the Prod registration to have less, check on Learn whether `ConfigurationMonitoring.Read.All` is enough for `createSnapshot` (the page lists only `ReadWrite`).

## Resource names (open, must be verified)

`Get-M365CloningDefaultResources` uses the documented pattern `microsoft.<workload>.<resource>`. Only `microsoft.entra.conditionalaccesspolicy` is named literally in the docs. The Intune, group and role names are inferred. Check each name against the *Supported ... resources* pages. A name the API does not know shows up as a failed or partial snapshot. Fix with `Resources = @(...)` in `config.psd1`.

## Run

1. `Copy-Item config.example.psd1 config.psd1` and fill in your Prod/Dev pair (real data stays in the git-ignored file).
2. Dry run, nothing is sent: `pwsh scripts/Get-DriftReport.ps1 -DryRun`
3. Get a token per tenant (your own way, certificate flow) as `SecureString`.
4. `pwsh scripts/Get-DriftReport.ps1 -ProdToken $prod -DevToken $dev`
5. Look at `History\reports\drift-*.md`.

## What to look at

| Check | Expected |
|---|---|
| Both snapshots end `succeeded` | `History\Tenants\Prod\<stamp>\meta.json` and `History\Tenants\Dev\...` exist |
| Snapshot shape | `snapshot.json` has `resources[]` with `displayName`, `resourceType`, `properties` (Learn: same schema as a configurationBaseline). If not, `Compare-TenantSnapshot` needs an adjustment. |
| Group names | Assignments carry `groupDisplayName`. If a resource type only has `groupId`, the report shows it as a difference (cannot be matched by name). Tell me which types. |
| Volatile fields | Differences that are only IDs or timestamps: tell me the property names, they go into the ignore list in `ConvertTo-FlatProperty`. |
| Equal tenants | A Dev tenant that is a copy of Prod gives an empty report. |
| Quotas | Snapshot: 20,000 resources per tenant per month, snapshots kept 7 days (we copy them). |
| Tenant untouched | Entra audit log / Intune audit shows only the snapshot job, no change. |

Report anything unexpected as an issue. The apply step is part 2, see below.

---

# Part 2: apply Prod -> Dev (writes to the Dev tenant)

Claude never ran any of this against a tenant. The unit tests use mocks; the DSC child process was not started. Do these steps in order and stop at the first surprise. Use a test object first (a new group or a policy named `ZZ-test-...` that exists in Prod and not in Dev).

## Before the first apply

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Windows PowerShell 5.1 and the Microsoft365DSC module | `powershell.exe -NoProfile -Command "Get-Module -ListAvailable Microsoft365DSC"` | Module found (run the DSC dependency installer the module documents if needed) |
| 2 | DSC resource names exist | `powershell.exe -NoProfile -Command "Get-DscResource -Module Microsoft365DSC -Name AADGroup,AADConditionalAccessPolicy,IntuneDeviceConfigurationPolicyWindows10,IntuneDeviceCompliancePolicyWindows10,IntuneRoleDefinition,AADRoleDefinition"` | All six found. The full list for Intune is in Part 5. A missing name: the runner fails only that action ("Microsoft365DSC has no resource ..."); tell me the name. |
| 3 | Dev app registration with certificate | Permissions as listed on Learn per resource (*Supported ... resources*: Update permissions, e.g. `Policy.ReadWrite.ConditionalAccess`, `Group.ReadWrite.All`, `DeviceManagementConfiguration.ReadWrite.All`) plus the Entra roles Learn names. Certificate in the current user's or machine's store, thumbprint in `config.psd1` | Sign-in works; **only in the Dev tenant**. The Prod registration has no write permission. |
| 4 | Break-glass accounts exist in Dev | `BreakGlass` (UPNs) and/or `BreakGlassGroups` (group names) in `config.psd1` | Accounts/groups exist in the Dev tenant. A name that does not exist makes the Conditional Access apply fail. |
| 5 | `Dev.ApplyAllowed = $true` | Only when you want to apply. Set it back to `$false` afterwards. | Without it every apply is refused and logged. |

## Run

1. Plan (nothing is changed): `pwsh scripts/Invoke-ApplyDev.ps1 -ConfigPath config.psd1 -SourceSnapshotPath <prod snapshot.json> -TargetSnapshotPath <dev snapshot.json>` (or with `-ProdToken` / `-DevToken`).
2. Read `History\reports\apply-plan-*.md`. Check that nothing is planned that you do not want in Dev.
3. Apply exactly that plan: same command with `-Apply -ConfirmPlanHash <hash from the plan>`. If a tenant changed since the preview the hash differs and the apply is refused.
4. `History\apply\<time>\result.json` and `History\audit.jsonl` show what happened.

## What to look at

| Check | Expected |
|---|---|
| Unverified: `Invoke-DscResource -Method Test/Set` with the DSC resources and certificate parameters (`ApplicationId`, `TenantId`, `CertificateThumbprint`) | One test object is created; if `Invoke-DscResource` is rejected, tell me the message (the runner is `src/M365Cloning/Dsc/Apply-DscPlan.ps1`) |
| Unverified: `Assignments` as CIM instances (`MSFT_DeviceManagementConfigurationPolicyAssignments`) | The assignment of the test policy shows the group by name in Intune |
| Unverified: property names of Intune and role resources in the snapshot (see the open resource-name check above) | The plan lists the properties you expect |
| Conditional Access | The policy is in Dev as **Report-only**, with the break-glass user/group in the exclusions, never enabled |
| Nothing deleted | A resource that only exists in Dev is still there after the apply |
| Blocked entries | Policies with an unknown group, assignment filter or specific users are listed as blocked and are not in Dev |
| Prod untouched | Entra audit log of the Prod tenant shows no change from the toolkit |
| Audit log | `History\audit.jsonl` has one line per plan, refusal and apply, no IDs of the app registration, no thumbprint |

# Part 3: Conditional Access copy with persona groups (writes to the Dev tenant)

Claude never ran any of this against a tenant (mocks and invented fixtures only). Same rules as Part 2; start with one policy.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Persona groups are recognised | Plan (Part 2, step 1) with a Prod snapshot that contains your Conditional Access policies. Look at the group rows `empty static copy (persona ...)` and at `Notes` | Your persona groups show the right persona. For a group with another Prod name: add it to `PersonaMap` in `config.psd1` and plan again |
| 2 | Empty copies in Dev | Apply, then look at the groups in the Dev tenant | Same names as in Prod, **static**, **no members**, no owners, no membership rule, no licences, no role assignment |
| 3 | Dynamic Prod groups | A dynamic Prod group in the plan | Created in Dev as a static empty group (the rule is not carried over) |
| 4 | Policy assignment | Open the copied policy in Dev | Include/Exclude point to the Dev groups with the same name; state **Report-only**; the break-glass accounts/groups are in the exclusions |
| 5 | Unknown group | A Prod policy that refers to a group without a persona that does not exist in Dev | The policy is **blocked** with `needs-group` and is not in Dev; no group was created for it |
| 6 | Break-glass group | `BreakGlassGroups` names a group that does not exist in Dev | The plan creates it empty. Put the Dev break-glass accounts into it yourself before you leave Report-only |
| 7 | Unverified: AADGroup creates a group from `DisplayName`, `MailNickname`, `SecurityEnabled`, `MailEnabled`, `Description`, `Ensure` | One test group | Created; if `Invoke-DscResource` rejects a property, tell me the message |
| 8 | Unverified: the group names in `IncludeGroups` / `ExcludeGroups` of `AADConditionalAccessPolicy` are display names | One test policy | The policy resolves the groups by name in Dev |
| 9 | Not done here: placing synchronised test users and admins into the persona groups (cross-tenant sync, nic2045/M365Backup-Cloning#7) | - | Follows with the reset/base configuration |


# Part 4: Dev users, test users and invited admins (writes to the Dev tenant)

Claude never ran any of this against a tenant (mocks and invented fixtures only). Same gate as Part 2 (`Dev.ApplyAllowed`, plan hash, Dev tenant only); start with one test user and one admin.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Permissions of the Dev registration | Application permissions as on Learn: `User.Create` (or `User.ReadWrite.All`) for *Create user*, `User.Invite.All` for *Create invitation*, `GroupMember.ReadWrite.All` for *Add members*; `User.Read.All` and `GroupMember.Read.All` (or `Group.Read.All`) for the reads | The plan reads users and groups; the apply writes. **Dev tenant only.** App-only invitations do not work if B2B invitations are switched off in Dev |
| 2 | Positive list | `DevUsers` in `config.psd1`: one `TestUser` with a UPN on a verified domain of the Dev tenant, one `AdminGuest` with the mail of an admin from Prod, each with a persona | `Import-M365CloningConfig` accepts it; an unknown persona, two personas, a break-glass account or a duplicate are refused |
| 3 | Plan | `pwsh scripts/Invoke-DevUsers.ps1 -DevToken $d` | `CreateUser`, `InviteGuest` and two `AddMember` rows planned; a persona whose group does not exist in Dev is `blocked` with `needs-group` |
| 4 | Apply | Same with `-Apply -ConfirmPlanHash <hash>`; once with `-ShowInitialPasswords`, once without | Test user exists, must change the password at first sign-in; the guest exists (no invitation mail was sent); both are members of their persona group. Without the switch no password is shown: reset it in the Entra admin center |
| 5 | Nothing else changed | A second plan right after the apply | Everything `exists`, nothing planned; no account was removed or disabled, no other group touched |
| 6 | No password on disk | Search `History\` for the password shown in step 4 | Not found (result file, report and audit log hold none) |
| 7 | Redemption without consent prompt | Cross-tenant access settings in Dev: inbound for the Prod tenant, trust setting **automatically redeem invitations** (and outbound in Prod) | The admin from Prod signs in to Dev without a consent prompt. The toolkit does **not** change this setting; it stays in place on a reset (#7) |
| 8 | Unverified: replication delay | An `AddMember` right after `CreateUser` | Works after the built-in retry (3 tries); if it fails with "objects being referenced don't exist", run the apply again (the membership is then planned for the existing account) |

# Part 5: Intune configuration Prod -> Dev (writes to the Dev tenant)

The UTCM type names are checked against the TCM schema that Learn links (`utcm-monitor.json`). The Microsoft365DSC resource names are not on Learn: they follow the rule `Intune` + resource name and are checked by the runner with `Get-DscResource` before use.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | DSC resource names for Intune | `powershell.exe -NoProfile -Command "Get-DscResource -Module Microsoft365DSC -Name IntuneDeviceAndAppManagementAssignmentFilter,IntuneDeviceCompliancePolicyWindows10,IntuneDeviceConfigurationPolicyWindows10,IntuneDeviceConfigurationEndpointProtectionPolicyWindows10,IntuneDeviceConfigurationAdministrativeTemplatePolicyWindows10,IntuneDeviceConfigurationCustomPolicyWindows10,IntuneSettingCatalogCustomPolicyWindows10,IntuneAntivirusPolicyWindows10SettingCatalog,IntuneEndpointDetectionAndResponsePolicyWindows10,IntuneSettingCatalogASRRulesPolicyWindows10,IntuneExploitProtectionPolicyWindows10SettingCatalog,IntuneApplicationControlPolicyWindows10,IntuneAccountProtectionPolicy,IntuneWindowsUpdateForBusinessRingUpdateProfileWindows10,IntuneWindowsUpdateForBusinessFeatureUpdateProfileWindows10"` | All 15 found. A missing one: tell me the name; until then the runner fails only that action |
| 2 | UTCM read permissions for the new types | Learn `utcm-intune-resources`, Read permissions per type (mostly `DeviceManagementConfiguration.Read.All`, `DeviceManagementApps.Read.All`, `Group.Read.All`) on the UTCM service principal in both tenants | The snapshot ends `succeeded` with the Intune types |
| 3 | Dev registration write permissions | Update permissions per type on Learn (mostly `DeviceManagementConfiguration.ReadWrite.All`, `DeviceManagementServiceConfig.ReadWrite.All`) | Apply works in Dev only |
| 4 | Snapshot shape for filters | Prod snapshot: `deviceandappmanagementassignmentfilter` resources carry `Identity`; policy assignments carry `deviceAndAppManagementAssignmentFilterId` | The plan maps the filter by name. If the filter's ID is under another property, tell me the name |
| 5 | Filter in two runs | A policy with a filter that Dev lacks | Run 1 creates the filter, the policy is `blocked` with `needs-filter`. New Dev snapshot, run 2: the policy is planned with the Dev filter ID |
| 6 | Assignment groups | A policy assigned to a group that Dev lacks | The group is created **empty and static** with the same name, the policy points to it by name. A missing **exclusion** group blocks the policy |
| 7 | Secrets | Wi-Fi, VPN, wired network, certificate profiles; a custom profile with an encrypted OMA-URI value | `skipped` with `secret: ...`, nothing in Dev. Create them in Dev by hand |
| 8 | Unverified: nested settings | Settings Catalog and endpoint security policies have nested settings (`Settings`, `TemplateReference`, ...) that the runner passes as hash tables; only `Assignments` become CIM instances | One test policy of each kind; if `Invoke-DscResource` rejects the nested settings, tell me the message (then they need CIM instances too) |
| 9 | Unverified: account protection assignments | `IntuneAccountProtectionPolicy` uses `MSFT_IntuneAccountProtectionPolicyAssignments` (schema) | The assignment is created |
| 10 | Not handled | Role scope tags (no TCM resource, not in the policy schemas); apps (SW-Depoyment uploads them) | Scope tags: set them in Dev by hand if you use them |

# Part 6: Dev base state (writes to the Dev tenant)

The UTCM type `microsoft.entra.crosstenantaccesspolicyconfigurationpartner` and its parameters (`PartnerTenantId`, `B2BCollaborationInbound`, `AutomaticUserConsentSettings`) are on Learn (`utcm-entra-resources`). The Microsoft365DSC name `AADCrossTenantAccessPolicyConfigurationPartner` and the CIM class names of the nested settings follow the naming rule; only `MSFT_AADCrossTenantAccessPolicyTarget` is named in the TCM schema.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | DSC resource and classes | `powershell.exe -NoProfile -Command "Get-DscResource -Module Microsoft365DSC -Name AADGroup,AADCrossTenantAccessPolicyConfigurationPartner \| Select-Object Name, Properties"` | Both found; the partner's properties show `AutomaticUserConsentSettings` and `B2BCollaborationInbound` with classes `MSFT_AADCrossTenantAccessPolicyAutomaticUserConsentSettings` and `MSFT_AADCrossTenantAccessPolicyB2BSetting`. Another class name: tell me |
| 2 | UTCM read permission | Learn `utcm-entra-resources`, Read permissions for `group` and `crossTenantAccessPolicyConfigurationPartner` on the UTCM service principal of Dev | The Dev snapshot ends `succeeded` with both types |
| 3 | Dev registration write permissions | Learn: `Group.ReadWrite.All` (groups) and `Policy.ReadWrite.CrossTenantAccess` (partner) on the Dev registration | Apply works in Dev only. The setup wizard (#18) will set these; the toolkit does not check them |
| 4 | Plan on a fresh Dev tenant | `pwsh scripts/Invoke-DevBaseline.ps1 -DevToken $d` | Break-glass group, persona groups and the partner are `planned` |
| 5 | Apply | Same with `-Apply -ConfirmPlanHash <hash>` | Groups exist, static, security, not mail-enabled, without members. Entra admin center > External Identities > Cross-tenant access settings: the Prod tenant is listed, B2B collaboration inbound allowed, trust setting "Automatically redeem invitations" on (inbound) |
| 6 | Base state reached | Plan again right after the apply | `Base state reached: no difference.` |
| 7 | Unverified: nested CIM settings | The runner turns entries with `__CimClass` into CIM instances (`New-CimInstance -ClientOnly`) before `Invoke-DscResource` | The partner is created. If `Invoke-DscResource` rejects the nested settings, tell me the message |
| 8 | Unverified: update of an existing partner | A partner with automatic redemption off | Only `AutomaticUserConsentSettings` (and an unset B2B inbound rule) change; B2B direct connect, outbound and inbound trust stay as they were |
| 9 | Not changed on purpose | A dynamic persona group; a B2B inbound rule for the Prod tenant limited to some groups | Both `blocked` with a reason; change them by hand if the base state should hold |

# Part 7: factory reset of Dev (deletes in the Dev tenant)

Only with your explicit go, only in the Dev tenant, always the plan first. Endpoints (Learn, checked 2026-11-07): v1.0 `DELETE /identity/conditionalAccess/policies/{id}` (plus `PATCH` with `state = 'disabled'` first), `/deviceManagement/deviceConfigurations/{id}`, `/deviceManagement/deviceCompliancePolicies/{id}`, `/groups/{id}`, `/users/{id}`; beta `/deviceManagement/configurationPolicies/{id}`, `/deviceManagement/intents/{id}`, `/deviceManagement/assignmentFilters/{id}`. Prod: v1.0 `directoryRoles(roleTemplateId='62e90394-69f5-4237-9190-012177145e10')/members`.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Permissions | Prod registration: `RoleManagement.Read.Directory`. Dev registration: `Directory.Read.All` (or `User.Read.All` + `Group.Read.All`), `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`, `DeviceManagementConfiguration.ReadWrite.All`, `DeviceManagementManagedDevices.Read.All`, `Group.ReadWrite.All`, `User.ReadWrite.All` | The plan reads without 403 |
| 2 | Config | `Dev.AllowReset = $true` only for the run; `ProtectedAccounts` holds at least your own Dev admin; `BreakGlass` set | Without them the plan refuses |
| 3 | Plan Align | `pwsh scripts/Invoke-DevReset.ps1 -ProdToken $p -DevToken $d` | Only Dev-only objects `planned`; the protection list shows your admins, break-glass, the Prod Global Administrators and their guests, the toolkit app and the Prod partner |
| 4 | Plan Full | Same with `-Mode Full` | The whole scope `planned`; guests, devices, synced objects, Microsoft 365 and role groups `skipped` |
| 5 | Lockout check | Temporarily remove your admin from `ProtectedAccounts` and `BreakGlass` in a copy of the config | The plan refuses ("protects no account" or "none of the protected accounts") |
| 6 | First run | Align on a Dev tenant with one test object only in Dev: `-Apply -ConfirmPlanHash <hash> -ConfirmTenant <Dev tenant ID>` | Only that object is deleted; one audit line per delete; you can still sign in |
| 7 | Restore check | Entra admin center > Deleted users / groups, Conditional Access deleted items | The deleted users, groups and policies are listed and restorable |
| 8 | Rebuild | `-RebuildAfter` on a test run | Base state, apply and users each ask for their plan hash; the drift report at the end is empty except for excluded points |
| 9 | Unverified | Deleting a filter or group still used by an object outside the scope (e.g. an app assignment) | Graph refuses; the step is `failed`, later steps `not-run`. Tell me the message |

# Part 8: Conditional Access dependencies (named locations, authentication strengths, methods)

Issue #33. Only in the Dev tenant, plan first. Sources (Learn, checked 2026-11-07): `utcm-entra-resources` sections `namedLocationPolicy`, `authenticationStrengthPolicy`, `authenticationMethodPolicy*`, `conditionalAccessPolicy` (IncludeLocations / ExcludeLocations / AuthenticationStrength by name); Graph v1.0 `DELETE /identity/conditionalAccess/namedLocations/{id}` and `DELETE /policies/authenticationStrengthPolicies/{id}` (custom policies only).

| # | Check | How | Expected |
|---|---|---|---|
| 1 | DSC resources | `powershell.exe -NoProfile -Command "Get-DscResource -Module Microsoft365DSC -Name AADNamedLocationPolicy,AADAuthenticationStrengthPolicy \| Select-Object Name"` | Both found. Another name: tell me (the names are inferred, Learn does not list them) |
| 2 | Snapshot values | Prod snapshot with a CA policy that uses a named location and a custom authentication strength | `IncludeLocations` / `ExcludeLocations` and `AuthenticationStrength` hold **names**. If they hold object IDs, the plan blocks the policy ("by ID"): tell me |
| 3 | Permissions | UTCM read: `Policy.Read.All`, `Policy.Read.AuthenticationMethod`. Dev registration write: `Policy.ReadWrite.ConditionalAccess`, `Policy.ReadWrite.AuthenticationMethod` | Snapshot and apply run without 403 |
| 4 | Plan | `pwsh scripts/Invoke-ApplyDev.ps1` against a Dev tenant without the location | The location and the custom strength are `planned` before the CA policy; the policy is `planned` (Report-only) |
| 5 | Apply | Same with `-Apply -ConfirmPlanHash <hash>` | Named location with the same ranges / countries and trusted mark; the strength with the same combinations; the CA policy names both |
| 6 | Built-in strengths | A CA policy with "Phishing-resistant MFA" | The policy is `planned`; the built-in strength is never created or changed. If the display name in your tenant differs, the policy is blocked: tell me the name |
| 7 | Methods report-only | Prod and Dev differ in an authentication method (e.g. FIDO2 on/off) | Drift report shows it; the plan says `skipped: report-only`; nothing changes |
| 8 | Reset | `scripts/Invoke-DevReset.ps1 -Mode Full` plan | Locations of break-glass policies are on the protection list; trusted locations `skipped`; custom locations and strengths deleted after the CA policies; built-in strengths not listed |
| 9 | Unverified | Reset deletes a named location still used by a policy outside the plan | Graph refuses; the step is `failed`, later steps `not-run`. Tell me the message |

# Part 9: licence check in the plan

Issue #32. Read only: the plan reads the Dev licences and blocks entries whose licence is missing. Sources (Learn, checked 2026-11-07): `List subscribedSkus` (GET, least privileged application permission `LicenseAssignment.Read.All`), `servicePlanInfo` (provisioningStatus), `Product names and service plan identifiers for licensing`, `Microsoft Entra licensing`. The rules are data: `src/M365Cloning/Data/LicenceRequirements.psd1`.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Permission | Dev registration: `LicenseAssignment.Read.All` (application) | The plan shows "## Licences" without "could not be read" |
| 2 | Save the list | `GET https://graph.microsoft.com/v1.0/subscribedSkus` with the Dev registration, save the JSON | Offline preview with `-LicencePath <file>` gives the same plan hash as the online plan |
| 3 | Service plan names | Compare the `servicePlanName` values of your SKUs with the rules (`AAD_PREMIUM`, `AAD_PREMIUM_P2`, `INTUNE_A`, `INTUNE_EDU`) | Your Intune and Entra plans appear under those names. Another name (e.g. a new Intune plan): tell me |
| 4 | Missing P2 | A Prod policy with sign-in or user risk, Dev without P2 | The policy is `blocked` with `license: Risk-based Conditional Access ...`; everything else stays `planned` |
| 5 | Not readable | Remove the permission for one run | Entries that need a licence are `blocked` with `license: not verified`; groups, users and invitations stay `planned` |
| 6 | PendingActivation | A SKU whose service plan shows `PendingActivation` | It counts as missing until it is activated (Learn: it needs an explicit activation) |
| 7 | Unverified | Entra ID Governance instead of P2 for PIM; terms of use | PIM accepts only `AAD_PREMIUM_P2` (the Governance plan name is not checked); terms of use only give a warning. Tell me if your tenant uses Governance |

# Part 10: copy all unless excluded (ADR 0006)

Claude never ran any of this against a tenant (mocks and invented fixtures only). Same gate as Part 2; look at the plan before any apply.

| Step | What | How | Expected |
|---|---|---|---|
| 1 | Snapshot of all default types | Drift report (Part 1) without `Resources` in `config.psd1` | The snapshot job accepts the type list of `Get-M365CloningDefaultResources` (Entra and Intune, without the excluded types). A type the service rejects: tell me its name, it goes on the exclusion list. |
| 2 | Plan per type | Plan (Part 2, step 1) and open the Markdown | The table "Per resource type" shows planned, blocked, skipped and excluded entries. Blocked generic entries name the property with a Prod object ID; decide per type: exclude it, or clear the field in Prod. |
| 3 | DSC names of generic types | The runner resolves each name with `Get-DscResource` (case does not matter) | A generic type without a Microsoft365DSC resource fails only its own action ("has no resource"); tell me the type. |
| 4 | Authentication contexts (#38) | A Conditional Access policy that uses an authentication context | The context (`c1` ... `c25`) is created first with the same key, the policy is planned; without the context in Prod or Dev the policy is `needs-auth-context`. |
| 5 | Enrollment (#35) | Prod with an enrollment status page, enrollment restrictions, an Autopilot profile | The defaults (priority 0) are `skipped: tenant default`. A platform restriction whose key `Identity` is a Prod object ID is blocked; an ESP with selected apps is blocked (apps are matched by ID). Tell me which ones Dev needs. |
| 6 | Exclusion list | `ExcludeResourceTypes` in `config.psd1` | The type is no longer in the snapshot; in a snapshot that still has it, its objects show `excluded: <reason>`. |

# Part 11: suitability check, is Dev enough? (issue #39)

Read only. Claude never ran it against a tenant (mocks and invented fixtures only).

| Step | What | How | Expected |
|---|---|---|---|
| 1 | Permission | App registrations of Prod and Dev have `LicenseAssignment.Read.All` (application) | `GET /subscribedSkus` works in both tenants |
| 2 | Run with tokens | `scripts/Invoke-TenantFitCheck.ps1 -ProdToken ... -DevToken ...` (uses the newest Prod snapshot in `History\Tenants\Prod\`) | A traffic light, exit code 0/1/2/3, `History\reports\tenantfit-*.md` and an audit line with mode `fitcheck` |
| 3 | Plausibility | Compare the findings with what you know of both tenants | Every yellow or red finding names the feature, the missing service plan and the Prod types that use it. A feature Prod has but does not use gives no finding |
| 4 | Capacity | `DevUsers` with test users, Dev with few free units | A yellow `capacity` finding (never red) when free units (enabled - consumed) are fewer than test users. Admin guests are not counted (B2B guests are billed by monthly active users) |
| 5 | Without access | Run without tokens or with a token that lacks the permission | Grey, exit code 3, `Verified: False`, "Not verified". That is on purpose: a scheduled run must not report green when it saw nothing |
| 6 | Schedule | Runbook as in `docs/automation.md` | The run writes its report and audit line; the job status follows the exit code |

# Part 12: devices in the reset (issue #46, ADR 0007)

Claude never ran any of this against a tenant (mocks and invented fixtures only). Start with a test device you can re-enrol.

| Step | What | How | Expected |
|---|---|---|---|
| 1 | Permissions | Dev app registration has `DeviceManagementManagedDevices.ReadWrite.All` (remove) and `DeviceManagementManagedDevices.PrivilegedOperations.All` (retire, wipe), application | Without them the run fails at the device step only, earlier steps are done |
| 2 | Default | `scripts/Invoke-DevReset.ps1` (plan) without device options | Every device `Keep / skipped`; the VM test devices (`Dev.ProtectedDevicePrefixes`) and devices of protected users `Keep / protected` |
| 3 | Retire one device | `-DeviceActionFile` with `@{ '<test device name>' = 'Retire' }`, plan, then `-Apply` with the same file | One `POST .../retire`; at the next check-in apps and profiles are removed; audit line `retired ManagedDevice: <name>` |
| 4 | Remove | `-DeviceAction Remove` on a Dev with one unprotected test device | The device object is gone from Intune; the device itself is unchanged (re-enrol to bring it back) |
| 5 | Wipe refused | `-DeviceAction Wipe` with `Dev.AllowDeviceWipe = $false` | The plan refuses: "Wipe refused" |
| 6 | Wipe (only if you really want it) | `Dev.AllowDeviceWipe = $true`, one test device in the file | One `POST .../wipe`; the device resets at its next check-in. Cannot be undone |
| 7 | Duplicate device name (#49) | Two test devices with the same name, `-DeviceActionFile` with `@{ '<shared name>' = 'Retire' }`, plan | Both entries `blocked: ambiguous device name`; a note names the shared name; nothing is written |
| 8 | Serial number | Same file with `@{ '<serial number of one device>' = 'Retire' }`, plan | Exactly that device `Retire / planned`, the other one `Keep / skipped`; check the serial number in the Intune admin center matches |

# Part 13: Web sign-in (issue #60, ADR 0010)

Claude never ran this against a tenant (own test keys and a fake Entra ID only). Use your own tenant; nothing here writes to Prod or Dev data.

| Step | What | How | Expected |
|---|---|---|---|
| 1 | API registration | Entra admin center > App registrations > New: name of your choice, single tenant. Manifest: `"accessTokenAcceptedVersion": 2`. Expose an API: Application ID URI `api://<app id>`, scope `access_as_user` (admins and users) | The registration exists; its application (client) ID is the API audience |
| 2 | App roles | Same registration > App roles: `Reader`, `Applier`, `Resetter` (allowed member types: users/groups; value exactly as written) | Three roles listed |
| 3 | Interface registration | New registration (or the same one) for the interface. Authentication > Add a platform: "Mobile and desktop applications" with redirect URI `http://localhost:8080/auth/callback` (local run, no secret). For a hosted instance use platform "Web" with `https://<your host>/auth/callback` and a client secret or certificate kept in your secret store. API permissions: the `access_as_user` scope of step 1, admin consent | Redirect URI and permission listed, consent granted |
| 4 | Groups | Enterprise applications > the API app > Users and groups: assign a group to `Reader` (and later `Applier`/`Resetter`). Properties: "Assignment required" = Yes | Only members of assigned groups can sign in |
| 5 | Settings | Set the variables of `docs/web-contract.md`, section "Sign-in", for API and interface (tenant ID, audience = API client ID, client ID, scope `api://<app id>/access_as_user`, redirect URI) | Both apps start without warnings |
| 6 | Sign in | Open `http://localhost:8080/`, "Sign in with Microsoft" with a member of the Reader group | Overview opens; header shows your name and `Roles: Reader`; pages show your data (no "Example data" banner) |
| 7 | No role | Sign in with an account that is in no assigned group (or remove "Assignment required" for this test and use an account without role) | Refused by Entra ID, or pages answer 403 ("This needs the role Reader") |
| 8 | API directly | `curl -i http://127.0.0.1:8000/api/status` without token; then with an expired or edited token | 401 with `{"code": "unauthorized", ...}` / `invalid-token` / `token-expired` |
| 9 | Sign out | "Sign out" in the header, then the browser's back button | Back on the sign-in page; old pages ask for sign-in again |
| 10 | Browser storage | Developer tools > Application: cookies, local and session storage; page source | Only `m365ui_session` (HttpOnly, SameSite=Lax; Secure on https); no token anywhere in storage or HTML |
| 11 | Local account (optional) | `python -m m365ui.passwords`, set `M365_UI_LOCAL_LOGIN=1`, user, hash, role and `M365CLONING_LOCAL_TOKEN_SECRET` (same value for API and interface); open the interface on the same machine | The local form appears only on `127.0.0.1`; a wrong password is refused; after five wrong attempts the form is locked for five minutes |
| 12 | Local account from elsewhere | Open the interface from another machine (bind with `--host 0.0.0.0` for this test only) or through a reverse proxy | No local form; a posted form is refused |
