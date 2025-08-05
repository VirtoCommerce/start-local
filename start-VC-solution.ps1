param (
    [string]$solutionFolder = "VirtoLocal"
)

$scriptsDir = Join-Path $solutionFolder "scripts"
$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

Write-Host "Starting VC solution..." -ForegroundColor Yellow
docker-compose -f $dockerComposePath up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to start VC solution" -ForegroundColor Red
    Write-Host "docker-compose command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ VC solution started" -ForegroundColor Green

Write-Host "Checking installed modules..." -ForegroundColor Yellow
Invoke-Expression "./$scriptsDir/check-installed-modules.ps1 -ApiUrl http://localhost:8090 -ContainerId '$solutionFolder-vc-platform-web-1' -watchUrlScriptPath $scriptsDir/watch-url-up.ps1"
Write-Host "✓ Installed modules checked" -ForegroundColor Green

Write-Host "Setting up sampledata..." -ForegroundColor Yellow
Invoke-Expression "./$scriptsDir/setup-sampledata.ps1 -ApiUrl http://localhost:8090 -Verbose -Debug"
Write-Host "✓ Sampledata set up" -ForegroundColor Green