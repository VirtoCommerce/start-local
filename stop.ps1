#Requires -Version 7.0
# Stops the solution folder's Docker stack and removes its containers. Volumes and images stay.
param (
    [string]$solutionFolder = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/scripts/_init.ps1"

$solutionPath = (Resolve-Path -LiteralPath $solutionFolder -ErrorAction Stop).Path
Push-Location -LiteralPath $solutionPath
try {
    Invoke-StartLocalMigration $solutionPath | Out-Null

    Write-Host 'Stopping VC solution...' -ForegroundColor Yellow
    Invoke-DockerCompose down --remove-orphans
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: docker compose down failed with exit code $LASTEXITCODE." -ForegroundColor Red
        exit 1
    }
    Write-Host '... VC solution stopped' -ForegroundColor Green
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    Pop-Location
}
