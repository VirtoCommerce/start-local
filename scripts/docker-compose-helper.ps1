# Docker Compose v2 only (D4): the 'docker compose' plugin, version 2.18.0 or later.

function Invoke-DockerCompose {
    # Runs `docker compose <args>`. Throws when the plugin is missing.
    if (-not (Test-DockerComposeAvailable)) {
        throw [System.InvalidOperationException]::new("'docker compose' (Compose v2) is not available. Install Docker Compose 2.18.0 or later.")
    }
    & docker compose @args
}

function Test-DockerComposeAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Get-Command docker -CommandType Application -ErrorAction Ignore)) {
        return $false
    }
    $null = & docker compose version 2>&1
    $LASTEXITCODE -eq 0
}

function Get-ComposeVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $version = & docker compose version --short 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("'docker compose version --short' failed: $version")
    }
    ([string]$version).Trim()
}

function Test-ComposeVersion {
    # True when the version is at least the minimum. 'v2.40.3' and '2.18.0-desktop.1' count as 2.40.3 and 2.18.0;
    # text that has no major.minor.patch counts as too old.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Version,
        [Parameter(Position = 1)][string]$Minimum = '2.18.0'
    )

    $pattern = '^v?(?<core>\d+\.\d+\.\d+)'
    $actual = [regex]::Match($Version.Trim(), $pattern)
    $required = [regex]::Match($Minimum.Trim(), $pattern)
    if (-not $required.Success) {
        throw [System.ArgumentException]::new("'$Minimum' is not a version.", 'Minimum')
    }
    if (-not $actual.Success) {
        return $false
    }
    [version]$actual.Groups['core'].Value -ge [version]$required.Groups['core'].Value
}
