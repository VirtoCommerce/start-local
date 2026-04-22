param (
    [string]$solutionFolder = "VirtoLocal"
)

$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

. "$solutionFolder/scripts/docker-compose-helper.ps1"

# Merge ALL provider override files so 'down' works regardless of which
# provider is set in .env (or if .env is missing/corrupt). Only the containers
# actually running will be stopped.
$validProviders = @("postgres", "mysql", "sqlserver")
$composeArgs = @("-f", $dockerComposePath)
foreach ($provider in $validProviders) {
    $providerOverridePath = "$solutionFolder/docker-compose.$provider.yml"
    if (Test-Path -Path $providerOverridePath) {
        $composeArgs += "-f"
        $composeArgs += $providerOverridePath
    }
}
$composeArgs += "down"

Write-Host "Stopping VC solution..." -ForegroundColor Yellow
Invoke-DockerCompose @composeArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to stop VC solution" -ForegroundColor Red
    Write-Host "docker compose command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "... VC solution stopped" -ForegroundColor Green
