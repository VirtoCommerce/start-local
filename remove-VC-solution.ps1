param (
    [string]$solutionFolder = "VirtoLocal"
)

$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

# Iterate over all known providers so volumes from inactive providers are also removed.
# Side-by-side data volumes (postgres_data, mysql_data, mssql_data) are only declared
# in their respective override files, so each must be brought down with -v.
$validProviders = @("postgres", "mysql", "sqlserver")

Write-Host "Stopping and removing VC solution from docker (all providers)..." -ForegroundColor Yellow
foreach ($provider in $validProviders) {
    $providerOverridePath = "$solutionFolder/docker-compose.$provider.yml"
    if (-not (Test-Path -Path $providerOverridePath)) {
        Write-Host "  - Override file not found, skipping: $providerOverridePath" -ForegroundColor DarkYellow
        continue
    }
    Write-Host "  - Removing for provider: $provider" -ForegroundColor Cyan
    docker-compose -f $dockerComposePath -f $providerOverridePath down -v
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    Warning: docker-compose down -v for '$provider' returned exit code $LASTEXITCODE" -ForegroundColor Yellow
    }
}
Write-Host "... VC solution stopped and all DB volumes removed" -ForegroundColor Green

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
