param (
    [string]$solutionFolder = "VirtoLocal"
)

$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

. "$solutionFolder/scripts/docker-compose-helper.ps1"

# Read DB_PROVIDER from .env
$envFile = Join-Path $solutionFolder ".env"
$dbProvider = (Get-Content $envFile | Select-String -Pattern "^DB_PROVIDER=").Line.Split('=')[1].Trim()
$validProviders = @("postgres", "mysql", "sqlserver")
if ($dbProvider -notin $validProviders) {
    Write-Host "Error: Invalid DB_PROVIDER '$dbProvider' in .env file. Must be one of: $($validProviders -join ', ')" -ForegroundColor Red
    exit 1
}

$dbOverridePath = "$solutionFolder/docker-compose.$dbProvider.yml"
if (-not (Test-Path -Path $dbOverridePath)) {
    Write-Host "Error: Docker compose override file not found: $dbOverridePath" -ForegroundColor Red
    exit 1
}

Write-Host "Stopping VC solution (provider: $dbProvider)..." -ForegroundColor Yellow
Invoke-DockerCompose -f $dockerComposePath -f $dbOverridePath down
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to stop VC solution" -ForegroundColor Red
    Write-Host "docker compose command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "... VC solution stopped" -ForegroundColor Green
