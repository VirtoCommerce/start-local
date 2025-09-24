param (
    [string]$targetFolder = "VirtoLocal",
    [ValidateSet("latest-stable", "edge")]
    [string]$vcSolutionVersion = "latest-stable"
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

if ($vcSolutionVersion -eq "latest-stable") {
    $vcModulesBundle = "latest"
    $packagesJsonUrl = "https://raw.githubusercontent.com/VirtoCommerce/vc-modules/refs/heads/master/bundles/$vcModulesBundle/package.json"
    $frontendZipUrl = (Invoke-WebRequest -Uri $packagesJsonUrl).Content | ConvertFrom-Json | Select-Object -ExpandProperty "ThemeB2BVue"
}
else {
    $vcModulesBundle = "edge"
    $releaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/VirtoCommerce/vc-frontend/releases/latest"
    $frontendZipUrl = $releaseInfo.assets.browser_download_url
}

# build backend
$backendDir = Join-Path $targetFolder "backend"
New-Folder $backendDir
if ($vcSolutionVersion -eq "latest-stable") {
    # build latest stable
    $stablePackagesJsonUrl = "https://raw.githubusercontent.com/VirtoCommerce/vc-modules/refs/heads/master/bundles/$vcModulesBundle/package.json"
    $stablePackagesJsonPath = Join-Path $backendDir "stable-packages.json"
    Invoke-WebRequest -Uri $stablePackagesJsonUrl -OutFile $stablePackagesJsonPath

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
    Write-Host "... Backend built successfully" -ForegroundColor Green
}
else {
    # build latest dev
    Write-Host "Building backend..." -ForegroundColor Yellow
    vc-build install -Edge `
        --probing-path $backendDir/publish/app_data/modules `
        --discovery-path $backendDir/publish/modules `
        --root $backendDir/publish `
        --skip-dependency-solving
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to build backend" -ForegroundColor Red
        Write-Host "Build command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
        exit 1
    }
    Write-Host "... Backend built successfully" -ForegroundColor Green
}

# build backend Docker image
Write-Host "Building backend Docker image..." -ForegroundColor Yellow
docker build --no-cache -t "vc-platform:local-latest" -f $backendDir/Dockerfile $backendDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to build backend Docker image" -ForegroundColor Red
    Write-Host "Build command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "... Backend Docker image built successfully" -ForegroundColor Green

#remove publish folder
Write-Host "Removing publish folder..." -ForegroundColor Yellow
if (Test-Path -Path $backendDir/publish) {
    Remove-Item -Recurse -Force $backendDir/publish
}
Write-Host "... Publish folder removed" -ForegroundColor Green

# download and extract frontend files
Write-Host "Downloading and extracting frontend files..." -ForegroundColor Yellow
$frontendDir = Join-Path $targetFolder "frontend"
New-Folder $frontendDir
Invoke-WebRequest -Uri $frontendZipUrl -OutFile $frontendDir/frontend.zip
Expand-Archive -Path $frontendDir/frontend.zip -DestinationPath $frontendDir/artifact
Remove-Item -Path $frontendDir/frontend.zip -Force
Write-Host "... Frontend files downloaded and extracted" -ForegroundColor Green

# build frontend Docker image
Write-Host "Building frontend Docker image..." -ForegroundColor Yellow
docker build -t "vc-frontend:local-latest" -f $frontendDir/Dockerfile $frontendDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to build frontend Docker image" -ForegroundColor Red
    Write-Host "Build command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "... Frontend Docker image built successfully" -ForegroundColor Green
Remove-Item -Recurse -Force $frontendDir/artifact

# Ask user to proceed with running the solution
$proceed = Read-Host "Do you want to proceed with running the VirtoCommerce solution? (Y/n)"
if ($proceed -eq "" -or $proceed -eq "y" -or $proceed -eq "Y") {
    Write-Host "Starting run process..." -ForegroundColor Yellow
    Invoke-Expression "./$targetFolder/start-VC-solution.ps1"
}
else {
    Write-Host "Run process skipped. You can run it manually later using: ./$targetFolder/start-VC-solution.ps1" -ForegroundColor Yellow
}
