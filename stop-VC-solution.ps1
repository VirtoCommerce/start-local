param (
    [string]$solutionFolder = "VirtoLocal"
)

$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

Write-Host "Stopping VC solution..." -ForegroundColor Yellow
docker-compose -f $dockerComposePath down
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to stop VC solution" -ForegroundColor Red
    Write-Host "docker-compose command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ VC solution stopped" -ForegroundColor Green