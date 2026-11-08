# Settings of the web app (issue #79). Copy to web.settings.psd1 (git-ignored) and fill in, then run
#   pwsh scripts/Start-M365CloningWeb.ps1
# Placeholders only: never commit real IDs. No client secret here: the interface is registered as a
# "Mobile and desktop applications" app with a http://localhost redirect and needs none (ADR 0010).
@{
    # Sign-in with Entra ID: the normal way to use the app (docs/getting-started.md, step 2).
    # Leave all three empty to run with the break-glass account only.
    Entra = @{
        TenantId    = ''   # Directory (tenant) ID of the tenant the admins sign in to
        ApiClientId = ''   # Application (client) ID of the API registration (app roles Reader, Applier, Resetter)
        UiClientId  = ''   # Application (client) ID of the interface registration
        # Optional; defaults: api://<ApiClientId>/access_as_user and http://localhost:<Ports.Ui>/auth/callback
        # ApiScope    = ''
        # RedirectUri = ''
    }

    # Break-glass account: only on this machine, management only (role Reader: read everything and check the
    # configuration; no reports, apply or reset; ADR 0016). Off by default.
    LocalAccount = @{
        Enabled      = $false
        User         = 'breakglass'
        PasswordHash = ''        # set by: pwsh scripts/Start-M365CloningWeb.ps1 -SetLocalPassword
        Role         = 'Reader'  # Reader only; Applier and Resetter are refused
    }

    # Both apps listen on 127.0.0.1 only.
    Ports = @{
        Api = 8000
        Ui  = 8080
    }

    # Optional: another History folder or config file (default: History\ and config.psd1 next to the toolkit).
    History    = ''
    ConfigPath = ''
}
