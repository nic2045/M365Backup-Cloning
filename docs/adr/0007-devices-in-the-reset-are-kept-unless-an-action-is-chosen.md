# 0007. Devices in the reset are kept unless an action is chosen

Status: Accepted (2026-11-07, decided with the owner in issue #46). Supersedes in part ADR 0005, point 4: devices are no longer "listed only".

## Context
ADR 0005 lists Intune devices in the reset plan but never touches them. To clean the Dev tenant and rebuild it in a controlled way, the operator also needs to remove or retire devices, from the command line now and later from the web interface (#14).

## Decision
1. **Default is keep.** Without a choice every device stays as it is, in Align and in Full mode.
2. **Actions per device or for all:** Keep, Remove (delete the managed device object in Intune; the device itself is not changed), Retire (company apps, profiles and data are removed at the next check-in; personal data stays). Command line: `-DeviceAction` for all devices, `-DeviceActionFile` with an action per device name.
3. **Wipe only on purpose.** A wipe (factory reset of the device) is refused unless the local configuration sets `Dev.AllowDeviceWipe = $true` (default `$false`). The plan, the run and the write allow list each check it.
4. **Protected devices are never touched:** devices whose name starts with one of `Dev.ProtectedDevicePrefixes` (for example the Intune VM test devices of the packaging tool) and devices whose primary user is on the protection list (break-glass, protected and service accounts, Global Administrators of Prod and their guests).
5. **Device actions run last,** after every other reset step succeeded. Retire and wipe cannot be undone, so a failure earlier in the run leaves all devices untouched.
6. **Write path:** the reset allow list accepts `DELETE /deviceManagement/managedDevices/{id}`, `POST .../{id}/retire` and `POST .../{id}/wipe` only when the plan carries device actions, Dev tenant only, plan hash and second confirmation as for the reset. Every device action gets its own audit line (kind and name, no IDs).

## Consequences
- The Dev app registration needs `DeviceManagementManagedDevices.ReadWrite.All` for remove and `DeviceManagementManagedDevices.PrivilegedOperations.All` for retire and wipe (Microsoft Learn); without them the run fails at the device step and stops there.
- Retire and wipe take effect at the next check-in of the device; until then the device can still appear in Intune.
- The web interface offers the same choices with #14.
