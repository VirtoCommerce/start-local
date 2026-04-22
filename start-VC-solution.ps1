param (
    [string]$solutionFolder = "VirtoLocal",
    [bool]$skipSampleData = $true
)
function Test-PortInUse {
    param([int]$Port)

    if ($IsWindows) {
        # Windows: use netstat
        $listeningPorts = netstat -an | Where-Object { $_ -match "LISTENING" }
        return $listeningPorts | Where-Object { $_ -match ":$Port\s" }
    }
    else {
        # Linux/macOS: use ss command (modern replacement for netstat)
        try {
            $ssOutput = ss -tuln | Where-Object { $_ -match "LISTEN" }
            return $ssOutput | Where-Object { $_ -match ":$Port\s" }
        }
        catch {
            # Fallback: try lsof if ss is not available
            try {
                $lsofOutput = lsof -i :$Port 2>$null
                return $lsofOutput | Where-Object { $_ -match "LISTEN" }
            }
            catch {
                Write-Warning "Could not check port $Port - port checking tools not available"
                return $null
            }
        }
    }
}

$scriptsDir = Join-Path $solutionFolder "scripts"
$dockerComposePath = "$solutionFolder/docker-compose.yml"
if (-not (Test-Path -Path $dockerComposePath)) {
    Write-Host "Error: Docker compose file not found: $dockerComposePath" -ForegroundColor Red
    exit 1
}

. "$scriptsDir/docker-compose-helper.ps1"

# Read DB_PROVIDER from .env
$envFile = Join-Path $solutionFolder ".env"
if (-not (Test-Path -Path $envFile)) {
    Write-Host "Error: .env file not found: $envFile" -ForegroundColor Red
    exit 1
}
$dbProviderLine = Get-Content $envFile | Select-String -Pattern "^DB_PROVIDER=" | Select-Object -First 1
if (-not $dbProviderLine) {
    Write-Host "Error: DB_PROVIDER is not set in $envFile" -ForegroundColor Red
    exit 1
}
$dbProvider = $dbProviderLine.Line.Split('=', 2)[1].Trim().ToLower()
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

Write-Host "Using database provider: $dbProvider" -ForegroundColor Cyan

# Determine which DB port to check based on provider
$dbPortVarMap = @{
    "postgres"  = "PGSQL_PORT"
    "mysql"     = "MYSQL_PORT"
    "sqlserver" = "MSSQL_PORT"
}
$dbPortVar = $dbPortVarMap[$dbProvider]

Write-Host "Checking required ports..." -ForegroundColor Yellow
$envContent = Get-Content $envFile

# Parse .env into a hashtable once — reused for port checks and URL building.
$envValues = @{}
foreach ($envLine in $envContent) {
    if ($envLine -match '^\s*([^#=\s][^=]*)=(.*)$') {
        $envValues[$matches[1].Trim()] = $matches[2].Trim()
    }
}

# Collect shared ports (non-DB) + the active DB port
$sharedPortVars = @("PLATFORM_PORT", "ES_PORT", "KIBANA_PORT", "REDIS_PORT", "FRONTEND_PORT")
$allPortVars = $sharedPortVars + @($dbPortVar)

$requiredPorts = @()
foreach ($varName in $allPortVars) {
    if ($envValues.ContainsKey($varName)) {
        $requiredPorts += $envValues[$varName]
    }
}

foreach ($port in $requiredPorts) {
    Write-Host "Checking port '$port'..."
    $portInUse = Test-PortInUse -Port $port
    if ($portInUse) {
        Write-Host "Local TCP port $port is busy, please review ports configuration in '.env' file" -ForegroundColor Red
        exit 1
    }
    else {
        Write-Host "... port '$port' is free"
    }
}
Write-Host "Ports check completed" -ForegroundColor Green

$platformPort = if ($envValues.ContainsKey("PLATFORM_PORT")) { $envValues["PLATFORM_PORT"] } else { "8090" }
$platformApiUrl = "http://localhost:$platformPort"

Write-Host "Starting VC solution..." -ForegroundColor Yellow
Invoke-DockerCompose -f $dockerComposePath -f $dbOverridePath up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to start VC solution" -ForegroundColor Red
    Write-Host "docker compose command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    exit 1
}
Write-Host "... VC solution started" -ForegroundColor Green

Write-Host "Checking installed modules..." -ForegroundColor Yellow
$solutionFolderLower = $solutionFolder.ToLower()
Invoke-Expression "./$scriptsDir/check-installed-modules.ps1 -ApiUrl $platformApiUrl -ContainerId '$solutionFolderLower-vc-platform-web-1' -watchUrlScriptPath $scriptsDir/watch-url-up.ps1"
Write-Host "... Installed modules checked" -ForegroundColor Green

if ($skipSampleData) {
    Write-Host "Skipping sampledata setup (--skipSampleData)" -ForegroundColor Yellow
}
else {
    Write-Host "Setting up sampledata..." -ForegroundColor Yellow
    Invoke-Expression "./$scriptsDir/setup-sampledata.ps1 -ApiUrl $platformApiUrl -Verbose -Debug"
    Write-Host "... Sampledata set up" -ForegroundColor Green
}
