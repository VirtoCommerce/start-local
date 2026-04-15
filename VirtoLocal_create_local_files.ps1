param (
    [string]$targetFolder = "VirtoLocal",
    [ValidateSet("postgres", "mysql", "sqlserver")]
    [string]$dbProvider = "",
    [string]$elasticsearchVersion = "8.18.0",
    [string]$branch = "dev"
)
function New-Folder($folder) {
    try {
        $folder = Resolve-Path $folder -ErrorAction Stop
        Write-Host "Folder exists: $folder" -ForegroundColor Green
    }
    catch {
        Write-Host "Target folder '$folder' does not exist, creating it..." -ForegroundColor Yellow
        New-Item $folder -ItemType Directory | Out-Null
    }
}

function New-RandomPassword {
    param([int]$Length = 12)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $password = ""
    for ($i = 0; $i -lt $Length; $i++) {
        $password += $chars[(Get-Random -Maximum $chars.Length)]
    }
    return $password
}

# create target folder
New-Folder $targetFolder

# Prompt for DB provider if not specified via parameter
if ([string]::IsNullOrWhiteSpace($dbProvider)) {
    Write-Host "Select your database provider:" -ForegroundColor Cyan
    Write-Host "1. PostgreSQL (default)" -ForegroundColor White
    Write-Host "2. MySQL" -ForegroundColor White
    Write-Host "3. SQL Server" -ForegroundColor White
    $dbChoice = Read-Host "Enter your choice (1, 2, or 3, default is 1)"

    switch ($dbChoice) {
        "2" { $dbProvider = "mysql" }
        "3" { $dbProvider = "sqlserver" }
        default { $dbProvider = "postgres" }
    }
}

Write-Host "Using database provider: $dbProvider" -ForegroundColor Green

# create .env file
Write-Host "Creating .env file..." -ForegroundColor Yellow
$envFile = Join-Path $targetFolder ".env"

$envFileContent = @"
DB_PROVIDER=$dbProvider

# PostgreSQL
PGSQL_VERSION=18.3
PGSQL_PORT=5432

# MySQL
MYSQL_VERSION=9.3
MYSQL_PORT=3306

# SQL Server
MSSQL_VERSION=2022-latest
MSSQL_PORT=1433

# Shared
DB_PASSWORD=$(New-RandomPassword)
STACK_VERSION=$elasticsearchVersion
PLATFORM_PORT=8090
ES_PORT=9200
KIBANA_PORT=5601
REDIS_PASSWORD=$(New-RandomPassword)
ELASTIC_PASSWORD=$(New-RandomPassword)
KIBANA_PASSWORD=$(New-RandomPassword)
REDIS_PORT=6379
FRONTEND_PORT=80
ES_CLUSTER_NAME=elasticsearch
ES_LICENSE=basic
ES_MEM_LIMIT=1g
"@
Set-Content -Path $envFile -Value $envFileContent
Write-Host "... .env file created" -ForegroundColor Green

# download management scripts
Write-Host "Downloading management scripts..." -ForegroundColor Yellow
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/build-VC-solution.ps1" -OutFile (Join-Path $targetFolder "build-VC-solution.ps1")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/start-VC-solution.ps1" -OutFile (Join-Path $targetFolder "start-VC-solution.ps1")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/stop-VC-solution.ps1" -OutFile (Join-Path $targetFolder "stop-VC-solution.ps1")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/remove-VC-solution.ps1" -OutFile (Join-Path $targetFolder "remove-VC-solution.ps1")
Write-Host "... Management scripts downloaded" -ForegroundColor Green

# download scripts-helpers
Write-Host "Downloading scripts-helpers..." -ForegroundColor Yellow
$scriptsDir = Join-Path $targetFolder "scripts"
$backendDir = Join-Path $targetFolder "backend"
$frontendDir = Join-Path $targetFolder "frontend"
New-Folder $scriptsDir
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/scripts/check-installed-modules.ps1" -OutFile (Join-Path $scriptsDir "check-installed-modules.ps1")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/scripts/setup-sampledata.ps1" -OutFile (Join-Path $scriptsDir "setup-sampledata.ps1")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/scripts/watch-url-up.ps1" -OutFile (Join-Path $scriptsDir "watch-url-up.ps1")
Write-Host "... Scripts-helpers downloaded" -ForegroundColor Green

# download config files for the backend
Write-Host "Downloading config files for the backend..." -ForegroundColor Yellow
New-Folder $backendDir
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/vc-docker/feat/net10/linux/platform/Dockerfile" -OutFile (Join-Path $backendDir "Dockerfile")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/vc-docker/feat/net10/linux/platform/wait-for-it.sh" -OutFile (Join-Path $backendDir "wait-for-it.sh")
Write-Host "... Config files for the backend downloaded" -ForegroundColor Green

# download config files for the frontend
Write-Host "Downloading config files for the frontend..." -ForegroundColor Yellow
New-Folder $frontendDir
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/frontend/Dockerfile" -OutFile (Join-Path $frontendDir "Dockerfile")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/frontend/nginx.conf" -OutFile (Join-Path $frontendDir "nginx.conf")
Write-Host "... Config files for the frontend downloaded" -ForegroundColor Green

# download docker-compose files (base + all provider overrides)
Write-Host "Downloading docker-compose files..." -ForegroundColor Yellow
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/docker-compose.yml" -OutFile (Join-Path $targetFolder "docker-compose.yml")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/docker-compose.postgres.yml" -OutFile (Join-Path $targetFolder "docker-compose.postgres.yml")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/docker-compose.mysql.yml" -OutFile (Join-Path $targetFolder "docker-compose.mysql.yml")
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/$branch/docker-compose.sqlserver.yml" -OutFile (Join-Path $targetFolder "docker-compose.sqlserver.yml")
Write-Host "... docker-compose files downloaded" -ForegroundColor Green

Write-Host "File operation completed." -ForegroundColor Green

# Update vc-build
$update = Read-Host "Do you want to update vc-build (Recommended)? (Y/n)"
if ($update -eq "" -or $update -eq "y" -or $update -eq "Y") {
    Write-Host "Updating vc-build..." -ForegroundColor Yellow
    dotnet tool update --global VirtoCommerce.GlobalTool
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Failed to update vc-build" -ForegroundColor Red
        Write-Host "dotnet tool update command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
        exit 1
    }
    else {
        Write-Host "... vc-build updated" -ForegroundColor Green
    }
}
else {
    Write-Host "vc-build update skipped." -ForegroundColor Yellow
}

# Ask user to proceed with building the solution
$proceed = Read-Host "Do you want to proceed with building the VirtoCommerce solution? (Y/n)"
if ($proceed -eq "" -or $proceed -eq "y" -or $proceed -eq "Y") {
    Write-Host "Starting build process..." -ForegroundColor Yellow

    # Ask user to select the version
    Write-Host "Select the version to install:" -ForegroundColor Cyan
    Write-Host "1. latest-stable - Latest stable bundle of backend with compatible frontend" -ForegroundColor White
    Write-Host "2. edge - Latest available releases of backend and frontend" -ForegroundColor White
    $versionChoice = Read-Host "Enter your choice (1 or 2, default is 1)"

    $vcSolutionVersion = "latest-stable"  # default
    if ($versionChoice -eq "2") {
        $vcSolutionVersion = "edge"
    }

    Write-Host "Using version: $vcSolutionVersion" -ForegroundColor Green
    Invoke-Expression "./$targetFolder/build-VC-solution.ps1 -vcSolutionVersion $vcSolutionVersion"
}
else {
    Write-Host "Build process skipped. You can run it manually later using: ./$targetFolder/build-VC-solution.ps1" -ForegroundColor Yellow
}
