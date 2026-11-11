# Shared by Invoke-Smoke.ps1 and Invoke-MigrationSmoke.ps1: dot-source it after scripts/_init.ps1. Defines functions only.

function Assert-Smoke {
    param(
        [Parameter(Mandatory, Position = 0)][bool]$Condition,
        [Parameter(Mandatory, Position = 1)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new("Smoke check failed: $Message")
    }
    Write-Host "OK: $Message" -ForegroundColor Green
}

function Assert-OutsideRepository {
    # Entry scripts never run with the repository root as the working directory, and a smoke never writes into it.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if ($Path.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [System.ArgumentException]::new("$ParameterName '$Path' is inside the repository '$RepositoryRoot'. Use a scratch folder outside it.", $ParameterName)
    }
}

function Start-ImagePull {
    # CIR items 1 and 3: pull the images in the background while the build downloads and compiles. Interpolation needs
    # the secrets, which are irrelevant to a pull, so they are dummies. The locally built vc-* images have no `build:`
    # section, so --ignore-buildable does not skip them; without --ignore-pull-failures the failed pull of those would
    # abort the others. A failed pull only warns: `docker compose up` pulls what is missing.
    param(
        [Parameter(Mandatory)][string]$Folder,
        # Arguments for `docker compose` before `pull`: the compose files or env files that select the services.
        [string[]]$ComposeArgument = @()
    )

    Start-Job -ArgumentList $Folder, $ComposeArgument -ScriptBlock {
        param($Folder, $ComposeArgument)

        Set-Location -LiteralPath $Folder
        foreach ($key in 'DB_PASSWORD', 'REDIS_PASSWORD', 'ELASTIC_PASSWORD', 'KIBANA_PASSWORD') {
            Set-Item -LiteralPath "env:$key" -Value 'pull-only'
        }
        $output = docker compose @ComposeArgument pull --quiet --ignore-buildable --ignore-pull-failures 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    }
}

function Wait-ImagePull {
    param([AllowNull()][System.Management.Automation.Job]$Job)

    if (-not $Job) {
        return
    }
    $pull = Receive-Job -Job $Job -Wait -AutoRemoveJob
    if ($pull.ExitCode -ne 0) {
        Write-Warning "The background image pull exited with code $($pull.ExitCode): $($pull.Output)"
    }
}

function Write-SmokeDiagnostics {
    # Container state and the last log lines, so a failed CI run can be debugged from its log.
    param([Parameter(Mandatory)][string]$Folder)

    Write-Host 'Container state and the last log lines, for the CI log:' -ForegroundColor Yellow
    if (-not (Test-Path -LiteralPath (Join-Path $Folder 'docker-compose.yml'))) {
        return
    }
    Push-Location -LiteralPath $Folder
    try {
        docker compose ps --all
        docker compose logs --tail 80
    }
    catch {
        Write-Host "Could not read the container logs: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    finally {
        Pop-Location
    }
}

function Invoke-SmokeInstall {
    # The installer in the role the bootstrap gives it (-payloadPath), with the repository as the payload, in-process.
    # With -TranscriptPath, what it writes to the host is also recorded there, for checks on its messages.
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$TranscriptPath
    )

    $installParameters = @{
        payloadPath    = $RepositoryRoot
        targetFolder   = $Target
        nonInteractive = $true
        releaseChannel = 'stable'
        skipSampleData = $true
    }
    $global:LASTEXITCODE = 0
    if ($TranscriptPath) {
        $null = Start-Transcript -LiteralPath $TranscriptPath -UseMinimalHeader
    }
    try {
        & (Join-Path $RepositoryRoot 'install.ps1') @installParameters
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($TranscriptPath) {
            $null = Stop-Transcript
        }
    }
    Assert-Smoke ($exitCode -eq 0) "install.ps1 exited with code $exitCode"
}
