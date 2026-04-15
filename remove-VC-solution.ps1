param (
    [string]$solutionFolder = "VirtoLocal"
)

$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

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

Write-Host "Stopping and removing VC solution from docker..." -ForegroundColor Yellow
docker-compose -f $dockerComposePath -f $dbOverridePath down -v
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove VC solution" -ForegroundColor Red
    Write-Host "docker-compose command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    # exit 1
} else {
    Write-Host "... VC solution stopped and removed" -ForegroundColor Green
}

Write-Host "Removing backend Docker image..." -ForegroundColor Yellow
docker rmi vc-platform:local-latest
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove backend Docker image" -ForegroundColor Red
    Write-Host "docker rmi command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    # exit 1
} else {
    Write-Host "... Backend Docker image removed" -ForegroundColor Green
}

Write-Host "Removing frontend Docker image..." -ForegroundColor Yellow
docker rmi vc-frontend:local-latest
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove frontend Docker image" -ForegroundColor Red
    Write-Host "docker rmi command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    # exit 1
} else {
    Write-Host "... Frontend Docker image removed" -ForegroundColor Green
}

Write-Host "Removing solution folder..." -ForegroundColor Yellow
Remove-Item -Recurse -Force $solutionFolder
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove solution folder" -ForegroundColor Red
    Write-Host "Remove-Item command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
} else {
    Write-Host "... Solution folder removed" -ForegroundColor Green
}

Write-Host "Done" -ForegroundColor Green
