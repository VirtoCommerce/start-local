param (
    [string]$targetFolder = "VirtoLocal",
    [string]$frontendRelease = "latest", # https://github.com/VirtoCommerce/vc-frontend/releases
    [string]$vcModulesBundle = "v10" # https://github.com/VirtoCommerce/vc-modules/tree/master/bundles
)

function New-Folder($folder) {
    try {
        $folder = Resolve-Path $folder -ErrorAction Stop
        Write-Host "Folder exists: $folder" -ForegroundColor Green
    }
    catch {
        Write-Host "Target folder '$folder' does not exist, creating it..." -ForegroundColor Yellow
        New-Item $folder -ItemType Directory
    }
}

# download packages.json file for the backend
$backendDir = Join-Path $targetFolder "backend"
New-Folder $backendDir
$stablePackagesJsonUrl = "https://raw.githubusercontent.com/VirtoCommerce/vc-modules/refs/heads/master/bundles/$vcModulesBundle/package.json"
$stablePackagesJsonPath = Join-Path $backendDir "stable-packages.json"
Invoke-WebRequest -Uri $stablePackagesJsonUrl -OutFile $stablePackagesJsonPath

# build backend
Write-Host "Building backend..." -ForegroundColor Yellow
vc-build install --package-manifest-path $stablePackagesJsonPath `
    --probing-path $backendDir/publish/app_data/modules `
    --discovery-path $backendDir/publish/modules `
    --root $backendDir/publish `
    --skip-dependency-solving
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to build backend" -ForegroundColor Red
    Write-Host "Build command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Backend built successfully" -ForegroundColor Green

# build backend Docker image
Write-Host "Building backend Docker image..." -ForegroundColor Yellow
docker build --no-cache -t "vc-platform:local-latest" -f $backendDir/Dockerfile $backendDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to build backend Docker image" -ForegroundColor Red
    Write-Host "Build command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Backend Docker image built successfully" -ForegroundColor Green

# #remove publish folder
# Write-Host "Removing publish folder..." -ForegroundColor Yellow
# if (Test-Path -Path $backendDir/publish) {
#     Remove-Item -Recurse -Force $backendDir/publish
# }
# Write-Host "✓ Publish folder removed" -ForegroundColor Green

# download and extract frontend files
Write-Host "Downloading and extracting frontend files..." -ForegroundColor Yellow
$frontendDir = Join-Path $targetFolder "frontend"
New-Folder $frontendDir
if ($frontendRelease -eq "latest") {
    $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/VirtoCommerce/vc-frontend/releases/latest"
}
else {
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/VirtoCommerce/vc-frontend/releases"
    $releaseInfo = $releases | Where-Object { $_.tag_name -eq $frontendRelease }
}
$assets = $releaseInfo.assets
$zipName = $assets.name
Invoke-WebRequest -Uri $assets.browser_download_url -OutFile $frontendDir/$zipName
Expand-Archive -Path $frontendDir/$zipName -DestinationPath $frontendDir/artifact
Remove-Item -Path $frontendDir/$zipName
Write-Host "✓ Frontend files downloaded and extracted" -ForegroundColor Green

# build frontend Docker image
Write-Host "Building frontend Docker image..." -ForegroundColor Yellow
docker build -t "vc-frontend:local-latest" -f $frontendDir/Dockerfile $frontendDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to build frontend Docker image" -ForegroundColor Red
    Write-Host "Build command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "✓ Frontend Docker image built successfully" -ForegroundColor Green
Remove-Item -Recurse -Force $frontendDir/artifact
