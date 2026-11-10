#Requires -Version 7.0
# Removes the solution folder's Docker stack. Full: containers, volumes, images and the folder.
# -keepData: containers, network, images and every file except .env; the volumes stay, and re-running the installer
# over the folder brings the stack back with its data (SPEC §8.1).
param (
    [string]$solutionFolder = $PSScriptRoot,
    [switch]$keepData,
    [switch]$nonInteractive
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/scripts/_init.ps1"

function Write-RemoveError {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host "Error: $Message" -ForegroundColor Red
}

$solutionPath = (Resolve-Path -LiteralPath $solutionFolder -ErrorAction Stop).Path
# Before anything else, even the migration: the repository root is a valid solution folder and must never be removed (P13).
if (-not (Test-RemovableFolder -Folder $solutionPath)) {
    Write-RemoveError "$solutionPath contains .git, so it is a repository checkout. Run remove.ps1 from an installed solution folder."
    exit 1
}
$envPath = Join-Path $solutionPath '.env'
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    Write-RemoveError "$envPath not found, so $solutionPath is not a start-local solution folder. Nothing was removed."
    exit 1
}
if (-not (Test-DockerComposeAvailable)) {
    Write-RemoveError "'docker compose' (Compose v2) is not available. Install Docker Compose 2.18.0 or later."
    exit 1
}

Push-Location -LiteralPath $solutionPath
try {
    # A layout 1 folder gets VOLUME_PREFIX=virto here, so the plan names its virto_* volumes.
    Invoke-StartLocalMigration $solutionPath | Out-Null
    $plan = Get-RemovalPlan -Folder $solutionPath -KeepData $keepData.IsPresent

    $isNonInteractive = Test-NonInteractive -Switch $nonInteractive.IsPresent -InputRedirected ([Console]::IsInputRedirected) -CiValue ([string]$env:CI)
    if (-not $isNonInteractive) {
        $scope = if ($keepData) { "every file except .env, and the containers and images (the volumes stay)" } else { "the containers, the volumes with all their data, the images and the folder" }
        $answer = Read-Host "Remove $scope of $solutionPath? [y/N]"
        if ($answer -notmatch '^\s*y(es)?\s*$') {
            Write-Host 'Nothing was removed.' -ForegroundColor Yellow
            exit 0
        }
    }

    if (Test-Path -LiteralPath (Join-Path $solutionPath 'docker-compose.yml') -PathType Leaf) {
        Write-Host 'Removing the Docker containers...' -ForegroundColor Yellow
        Invoke-DockerCompose @($plan.DownArgs)
        if ($LASTEXITCODE -ne 0) {
            # Deleting files or volumes under running containers would orphan them.
            Write-RemoveError "docker compose $($plan.DownArgs -join ' ') failed with exit code $LASTEXITCODE. Nothing else was removed."
            exit 1
        }
        Write-Host '... containers removed' -ForegroundColor Green
    }
    else {
        Write-Host 'No docker-compose.yml in the folder, so there are no containers to remove.' -ForegroundColor DarkYellow
    }

    # Safety net: compose's own `down -v` removes the volumes the active files declare; this removes the rest by name.
    foreach ($volume in $plan.Volumes) {
        docker volume inspect $volume *> $null
        if ($LASTEXITCODE -ne 0) {
            continue
        }
        Write-Host "  - Removing volume: $volume" -ForegroundColor Cyan
        $output = docker volume rm $volume 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to remove volume ${volume}: $output"
        }
    }

    foreach ($image in $plan.Images) {
        Write-Host "Removing image $image..." -ForegroundColor Yellow
        $output = docker rmi $image 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to remove image ${image}: $output"
        }
    }
}
catch {
    Write-RemoveError $_.Exception.Message
    exit 1
}
finally {
    # Leave the folder first: it may be about to be deleted.
    Pop-Location
}

try {
    Write-Host 'Removing files...' -ForegroundColor Yellow
    # Run from inside the folder, the script's location is the folder being deleted, which PowerShell refuses to remove.
    $currentPath = (Get-Location).ProviderPath
    if (-not $keepData -and ($currentPath -eq $solutionPath -or $currentPath.StartsWith($solutionPath.TrimEnd('/', '\') + [System.IO.Path]::DirectorySeparatorChar))) {
        Set-Location -LiteralPath (Split-Path -Parent $solutionPath)
    }
    foreach ($path in $plan.DeletePaths) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    }
}
catch {
    Write-RemoveError "Failed to remove files from '$solutionPath': $($_.Exception.Message)"
    exit 1
}

if ($keepData) {
    Write-Host "... Done. The volumes and $envPath are kept; run install.ps1 over the folder to restore the stack." -ForegroundColor Green
}
else {
    Write-Host '... Done' -ForegroundColor Green
}
