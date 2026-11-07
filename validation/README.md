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
