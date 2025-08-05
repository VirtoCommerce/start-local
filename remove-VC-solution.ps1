param (
    [string]$solutionFolder = "VirtoLocal"
)

$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

Write-Host "Stopping and removing VC solution from docker..." -ForegroundColor Yellow
docker-compose -f $dockerComposePath down -v
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove VC solution" -ForegroundColor Red
    Write-Host "docker-compose command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ VC solution stopped and removed" -ForegroundColor Green

Write-Host "Removing backend Docker image..." -ForegroundColor Yellow
docker rmi vc-platform:local-latest
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove backend Docker image" -ForegroundColor Red
    Write-Host "docker rmi command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Backend Docker image removed" -ForegroundColor Green

Write-Host "Removing frontend Docker image..." -ForegroundColor Yellow
docker rmi vc-frontend:local-latest
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove frontend Docker image" -ForegroundColor Red
    Write-Host "docker rmi command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Frontend Docker image removed" -ForegroundColor Green

Write-Host "Removing solution folder..." -ForegroundColor Yellow
Remove-Item -Recurse -Force $solutionFolder
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to remove solution folder" -ForegroundColor Red
    Write-Host "Remove-Item command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Solution folder removed" -ForegroundColor Green

Write-Host "Done" -ForegroundColor Green