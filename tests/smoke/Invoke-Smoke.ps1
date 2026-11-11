#Requires -Version 7.0
# Smoke test (SPEC §12): a non-interactive install of the default PostgreSQL stack in HTTPS mode, without Kibana
# and with Elasticsearch capped, then three checks against the running platform:
#   - /health answers 200;
#   - a token is issued for admin with the ADMIN_PASSWORD from .env;
#   - /api/platform/modules lists at least 23 installed modules.
# The stack is left running: CI runners are discarded, and locally the folder's remove.ps1 takes it down.
param (
    [Parameter(Mandatory)][string]$TargetFolder,
    [ValidateRange(1, [int]::MaxValue)][int]$MinInstalledModules = 23
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
. (Join-Path $repositoryRoot 'scripts/_init.ps1')
. (Join-Path $PSScriptRoot '_smoke.ps1')

$target = [System.IO.Path]::GetFullPath($TargetFolder)
$parent = Split-Path -Parent $target
Assert-OutsideRepository -Path $target -RepositoryRoot $repositoryRoot -ParameterName 'TargetFolder'
if (Test-Path -LiteralPath $target) {
    throw [System.ArgumentException]::new("TargetFolder '$target' already exists. Smoke starts from an empty folder.", 'TargetFolder')
}

$pullJob = $null
$null = New-Item -ItemType Directory -Path $target
# Entry scripts never run with the repository root as the working directory.
Push-Location -LiteralPath $parent
try {
    # 1. The default PostgreSQL HTTPS list, without Kibana and with the capped Elasticsearch. A .env with a COMPOSE_FILE
    # and no layout marker is what a cloud wrapper writes (R35): the installer completes it.
    $composeFiles = Get-DefaultComposeFiles -Provider postgres -Https $true
    $composeFiles = Set-ComposeFeature $composeFiles kibana $false
    $composeFiles = Set-ComposeFeature $composeFiles esLimited $true
    $envPath = Join-Path $target '.env'
    $envLines = @('COMPOSE_PATH_SEPARATOR=;', "COMPOSE_FILE=$(ConvertTo-ComposeFileValue $composeFiles ';')")
    Set-Content -LiteralPath $envPath -Value $envLines -Encoding utf8NoBOM
    Write-Host "COMPOSE_FILE: $($composeFiles -join '; ')" -ForegroundColor Cyan

    # The pull needs the compose files next to the .env; the installer copies the same payload again.
    Copy-Payload -Root $repositoryRoot -Destination $target
    # The folder's .env is still the wrapper's two lines, so .env.example supplies the ports and versions that interpolation needs.
    $pullJob = Start-ImagePull -Folder $target -ComposeArgument '--env-file', '.env.example', '--env-file', '.env'

    # 2. The installer, with the repository as the payload.
    Invoke-SmokeInstall -Target $target -RepositoryRoot $repositoryRoot

    # 3. The running platform, over HTTPS, without trusting the development certificate.
    $document = Read-EnvFile -Path $envPath
    $platformUrl = "https://localhost:$(Get-EnvValue -Document $document -Key 'PLATFORM_PORT' -Default '8090')"
    $adminPassword = [string](Get-EnvValue -Document $document -Key 'ADMIN_PASSWORD')
    Assert-Smoke (-not [string]::IsNullOrEmpty($adminPassword)) 'ADMIN_PASSWORD is set in .env'

    $isHealthy = Watch-Url-Up -ApiUrl "$platformUrl/health" -TimeoutMinutes 3 -RetrySeconds 10 -WaitSeconds 0
    Assert-Smoke $isHealthy "$platformUrl/health answers 200"

    $token = Get-AuthToken -AppAuthUrl "$platformUrl/connect/token" -Username 'admin' -Password $adminPassword
    Assert-Smoke (-not [string]::IsNullOrWhiteSpace($token)) 'a token is issued for admin with ADMIN_PASSWORD'

    # No @() around the call: Invoke-RestMethod emits the JSON array as one object, and @() would make it a one-element array.
    $modules = Invoke-RestMethod -Uri "$platformUrl/api/platform/modules" -Headers @{ Authorization = "Bearer $token" } -SkipCertificateCheck
    $installedModules = @($modules | Where-Object { $_.isInstalled }).Count
    Assert-Smoke ($installedModules -ge $MinInstalledModules) "$installedModules modules are installed (at least $MinInstalledModules expected)"

    Write-Host 'Smoke passed.' -ForegroundColor Green
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-SmokeDiagnostics -Folder $target
    exit 1
}
finally {
    Wait-ImagePull -Job $pullJob
    Pop-Location
}
exit 0
