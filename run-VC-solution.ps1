param (
    [string]$solutionName = "VirtoLocal",
    [string]$solutionFolder = "VirtoLocal"
)

# build backend
vc-build install --package-manifest-path $packagesJsonPath `
    --probing-path ./backend/publish/platform/app_data/modules `
    --discovery-path ./backend/publish/modules `
    --root ./backend/publish/platform `
    --skip-dependency-solving

# build backend Docker image
docker build --no-cache -t "vc-platform:local-latest" -f .\backend\Dockerfile .

# remove publish folder
if (Test-Path -Path ./backend/publish) {
    Remove-Item -Recurse -Force ./backend/publish
}

if ($installFrontend) {
    # Get the latest frontend release artifact
    if ($frontendRelease -eq "latest") {
        $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/VirtoCommerce/vc-frontend/releases/latest"
    }
    else {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/VirtoCommerce/vc-frontend/releases"
        $releaseInfo = $releases | Where-Object { $_.tag_name -eq $frontendRelease }
    }
    $assets = $releaseInfo.assets
    $zipName = $assets.name
    Invoke-WebRequest -Uri $assets.browser_download_url -OutFile ./frontend/$zipName
    Expand-Archive -Path ./frontend/$zipName -DestinationPath ./frontend/artifact
    Remove-Item -Path ./frontend/$zipName

    # build frontend Docker image
    Write-Host "Building frontend Docker image..." -ForegroundColor Yellow
    $buildResult = docker build -t "vc-frontend:local-latest" -f .\frontend\Dockerfile .
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to build frontend Docker image" -ForegroundColor Red
        Write-Host "Build command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
        Write-Host "Build output: $buildResult" -ForegroundColor Red
        exit 1
    }
    Write-Host "... Frontend Docker image built successfully" -ForegroundColor Green
    Remove-Item -Recurse -Force ./frontend/artifact
}

# Read DB_PROVIDER from .env and start with correct override
$envFile = Join-Path $solutionFolder ".env"
$dbProvider = (Get-Content $envFile | Select-String -Pattern "^DB_PROVIDER=").Line.Split('=')[1].Trim()

docker-compose -f $solutionFolder/docker-compose.yml -f $solutionFolder/docker-compose.$dbProvider.yml up -d
