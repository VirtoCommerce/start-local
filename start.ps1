#Requires -Version 7.0
# Starts the solution folder's Docker stack. Configuration lives in .env; the parameters below are saved into it (SPEC §8).
param (
    [string]$solutionFolder = $PSScriptRoot,
    [ValidateSet('postgres', 'mysql', 'sqlserver')]
    [string]$dbProvider,
    [switch]$allowInsecureHttp,
    # --- Skip parts ---
    [switch]$skipPlatform,
    [switch]$skipFrontend,
    [switch]$skipElasticsearch,
    [switch]$skipKibana,
    [switch]$skipRedis,
    # --- Per run ---
    [bool]$skipSampleData = $true,
    [switch]$nonInteractive
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/scripts/_init.ps1"

function Write-StartError {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host "Error: $Message" -ForegroundColor Red
}

$solutionPath = (Resolve-Path -LiteralPath $solutionFolder -ErrorAction Stop).Path
Push-Location -LiteralPath $solutionPath
try {
    Invoke-StartLocalMigration $solutionPath | Out-Null

    $envPath = Join-Path $solutionPath '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        Write-StartError "$envPath not found. Run install.ps1 first."
        exit 1
    }
    $document = Read-EnvFile -Path $envPath

    $isNonInteractive = Test-NonInteractive -Switch $nonInteractive.IsPresent -InputRedirected ([Console]::IsInputRedirected) -CiValue ([string]$env:CI)

    foreach ($warning in (Update-EnvFromOptions -Document $document -Bound $PSBoundParameters)) {
        Write-Warning $warning
    }
    $missingKeys = Request-RequiredEnvKeys -Document $document -NonInteractive $isNonInteractive
    if (-not $isNonInteractive -and $missingKeys.Count -gt 0) {
        # A non-interactive run reports its missing keys with the other preflight errors.
        Write-StartError "set $($missingKeys -join ', ') in $envPath."
        exit 1
    }

    $separator = Get-EnvValue -Document $document -Key 'COMPOSE_PATH_SEPARATOR' -Default ';'
    if ([string]::IsNullOrEmpty($separator)) {
        $separator = ';'
    }
    # The preflight reads the values as the user left them: normalizing an empty COMPOSE_FILE would hide that it is missing.
    $envValues = Get-EnvTable -Document $document
    $listedFiles = Get-ComposeFileList ([string]$envValues['COMPOSE_FILE']) $separator
    # P16: the source modules' bind mounts live in a generated compose file, written or removed on every run. Only a
    # Docker platform mounts them; a mixed or invalid MODULE_SOURCE_PATHS gives no mounts here and is reported by the preflight.
    # The plan is computed here, but the file changes only together with COMPOSE_FILE below: Compose fails at project load
    # when .env lists a missing file, so a deletion before the preflight could strand a running stack.
    $mountPlan = @()
    if ($listedFiles -ccontains 'docker-compose.platform.yml') {
        $mountPlan = Get-ModuleMountPlan -Classification (Get-ModuleSourceKind -Paths (Split-ModuleSourcePaths ([string]$envValues['MODULE_SOURCE_PATHS'])))
    }
    $composeFiles = Update-ComposeFileList -ComposeFiles $listedFiles -HasSourceModules ($mountPlan.Count -gt 0)

    Write-Host 'Checking the environment...' -ForegroundColor Yellow
    $preflightErrors = Invoke-Preflight -EnvValues $envValues -ComposeFiles $composeFiles -NonInteractive $isNonInteractive
    if ($preflightErrors.Count -gt 0) {
        foreach ($preflightError in $preflightErrors) {
            Write-StartError $preflightError
        }
        exit 1
    }
    Write-Host '... environment is ready' -ForegroundColor Green

    Write-ModulesComposeFile -SolutionFolder $solutionPath -MountPlan $mountPlan
    Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value (ConvertTo-ComposeFileValue $composeFiles $separator)
    Write-EnvFile -Document $document -Path $envPath
    $features = Get-ComposeFeatures -ComposeFiles $composeFiles

    $usesDevCertificate = $features.Https
    if ($usesDevCertificate) {
        # Before up: the platform and the storefront read the certificate from the certificates volume.
        Write-Host 'Copying the development certificate into the certificates volume...' -ForegroundColor Yellow
        Sync-DevCertificate -SolutionFolder $solutionPath -VolumeName (Get-CertsVolumeName -Document $document -SolutionFolder $solutionPath) -ProjectName (Get-SolutionProjectName -Document $document -SolutionFolder $solutionPath)
        Write-Host '... Development certificate ready' -ForegroundColor Green
    }

    Write-Host 'Starting VC solution...' -ForegroundColor Yellow
    Invoke-DockerCompose up -d --remove-orphans
    if ($LASTEXITCODE -ne 0) {
        Write-StartError "docker compose up failed with exit code $LASTEXITCODE."
        exit 1
    }
    Write-Host '... VC solution started' -ForegroundColor Green

    $serviceUrls = Get-ServiceUrls -EnvValues (Get-EnvTable -Document $document) -ComposeFiles $composeFiles
    if ($features.Platform) {
        $platformUrl = ($serviceUrls | Where-Object { $_.Name -eq 'Platform' }).Url
        $adminPassword = [string](Get-EnvValue -Document $document -Key 'ADMIN_PASSWORD')

        # The checks below report their own failures; none stops the run.
        Write-Host 'Checking installed modules...' -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        & (Join-Path $PSScriptRoot 'scripts/check-installed-modules.ps1') -ApiUrl $platformUrl -AdminPassword $adminPassword -OnFailureLog { docker compose logs --tail 50 vc-platform-web }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'The installed modules check failed; the solution is running anyway.'
        }
        else {
            Write-Host '... Installed modules checked' -ForegroundColor Green
        }

        if ($skipSampleData) {
            Write-Host 'Skipping sampledata setup (-skipSampleData)' -ForegroundColor Yellow
        }
        else {
            Write-Host 'Setting up sampledata...' -ForegroundColor Yellow
            $global:LASTEXITCODE = 0
            & (Join-Path $PSScriptRoot 'scripts/setup-sampledata.ps1') -ApiUrl $platformUrl -AdminPassword ([string](Get-EnvValue -Document $document -Key 'ADMIN_PASSWORD'))
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'Sample data setup failed; the solution is running anyway.'
            }
            else {
                Write-Host '... Sampledata set up' -ForegroundColor Green
            }
        }

        if ($isNonInteractive) {
            # C1: a non-interactive run owns the admin password. After the sample data: its Users section updates admin
            # with the seeded password hash. A freshly generated password cannot be on the platform yet, so only the
            # seeded password is tried to sign in.
            $signInPassword = $adminPassword
            if ([string]::IsNullOrEmpty($adminPassword)) {
                $adminPassword = New-RandomPassword
                Set-EnvValue -Document $document -Key 'ADMIN_PASSWORD' -Value $adminPassword
                Write-EnvFile -Document $document -Path $envPath
                Write-Host 'Generated ADMIN_PASSWORD and saved it in .env.' -ForegroundColor Yellow
            }
            $adminToken = Get-AdminToken -ApiUrl $platformUrl -AdminPassword $signInPassword
            if ([string]::IsNullOrWhiteSpace($adminToken)) {
                Write-Warning "The platform at $platformUrl accepts none of the admin passwords, so ADMIN_PASSWORD was not applied."
            }
            elseif (Set-AdminPassword -ApiUrl $platformUrl -Token $adminToken -NewPassword $adminPassword) {
                Write-Host 'Admin password applied from ADMIN_PASSWORD.' -ForegroundColor Green
            }
        }
    }

    Write-Host ''
    Write-Host 'Services:' -ForegroundColor Cyan
    foreach ($service in $serviceUrls) {
        Write-Host ('  {0,-14} {1}' -f $service.Name, $service.Url)
    }
    if ($usesDevCertificate -and -not (Test-DevCertificateTrusted)) {
        Write-Host ''
        Write-Host (Get-TrustInstructions) -ForegroundColor Yellow
        if ($features.Elasticsearch) {
            Write-Host 'Elasticsearch uses its own setup CA. To trust it the same way, copy it out of the setup container first:' -ForegroundColor Yellow
            Write-Host '     docker compose cp es-setup:/usr/share/elasticsearch/config/certs/ca/ca.crt ./ca.crt' -ForegroundColor Yellow
        }
    }
    $global:LASTEXITCODE = 0
}
catch {
    Write-StartError $_.Exception.Message
    exit 1
}
finally {
    Pop-Location
}
