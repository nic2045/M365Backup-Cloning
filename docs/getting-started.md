# Getting started with the web app

Five steps to run the web app on your admin machine (Windows first; Linux and macOS work the same way). Nothing here
writes into a tenant: you register the apps yourself, the toolkit only reads its settings. Background: ADR 0010, ADR 0016.

## 1. Install

- PowerShell 7.2 or later and Python **3.12** (python.org; on Windows tick the `py` launcher). The lock files are made
  for 3.12, so another version is refused with a clear message.
- The toolkit itself (`config.psd1` filled in, see the README) for the jobs.

## 2. Register the two apps in Entra ID (normal sign-in)

In the tenant your admins sign in to, *Entra admin center > App registrations*:

| Registration | What to set |
|---|---|
| API | New registration, single tenant. Manifest `"accessTokenAcceptedVersion": 2`. *Expose an API*: Application ID URI `api://<app id>`, scope `access_as_user`. *App roles*: `Reader`, `Applier`, `Resetter` (members: users/groups, value exactly as written) |
| Interface | New registration, single tenant. *Authentication > Add a platform > Mobile and desktop applications*, redirect URI `http://localhost:8080/auth/callback` (no client secret). *API permissions*: `access_as_user` of the API, admin consent |

Then *Enterprise applications > the API app > Users and groups*: assign groups to the roles. Give yourself (through a
group) **Resetter**; it includes Reader. Set *Assignment required* to Yes.

## 3. Fill in the settings

```powershell
Copy-Item web.settings.example.psd1 web.settings.psd1   # git-ignored
notepad web.settings.psd1
```

Put in the tenant ID and the two application (client) IDs from step 2. Nothing else is needed; the defaults are ports
8000 (API) and 8080 (interface).

**Break-glass account (optional).** For when Entra ID sign-in is not possible: set `LocalAccount.Enabled = $true` and run

```powershell
pwsh scripts/Start-M365CloningWeb.ps1 -SetLocalPassword
```

It asks for the password once (at least 12 characters) and stores only its hash. The account works only on this machine
and only reads: you can look at everything and check the configuration, but reports, apply and reset need Entra ID.

## 4. Check

```powershell
pwsh scripts/Start-M365CloningWeb.ps1 -Check
```

It checks Python, the settings and the ports and starts nothing. Every problem is listed with what to do.

## 5. Start

```powershell
pwsh scripts/Start-M365CloningWeb.ps1
```

The first start sets up the Python environments under `web.local\` (once, about a minute) and makes the shared token
secret (`web.local\token.secret`, only your account can read it). Then the browser opens on `http://localhost:8080/`.
Sign in with Microsoft, and the overview tells you the next step (usually *Settings > Setup check*). Ctrl+C stops both
apps. `-NoBrowser` leaves the browser closed.
