Param(
    # [parameter(Mandatory = $true)]
    $ApiUrl = 'http://localhost:8090',
    $Username = "admin",
    $Password = "store",
    $ContainerId = "",
    $watchUrlScriptPath = "./scripts/watch-url-up.ps1",
    [int]$MinInstalledModules = 23
)

$ErrorActionPreference = "Stop"

function Get-ContainerIdByImage {
    param (
        [string]$ContainerName = "platform"
    )
    
    try {
        $containers = docker ps --filter "name=$ContainerName" --format "table {{.ID}}\t{{.Image}}\t{{.Names}}" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to get container information: $containers"
            return $null
        }
        
        $containerLines = $containers -split "`n" | Where-Object { $_ -match '\S' }
        
        if ($containerLines.Count -eq 0) {
            Write-Error "No containers found with image '$ContainerName'"
            return $null
        }
        
        # Skip header line and get the first container ID
        $containerInfo = $containerLines[1] -split '\s+'
        $containerId = $containerInfo[0]
        
        Write-Host "Found container with image '$ContainerName': $containerId"
        return $containerId
    }
    catch {
        Write-Error "Error getting container ID: $_"
        return $null
    }
}

# Get container ID if not provided
if ([string]::IsNullOrEmpty($ContainerId)) {
    $ContainerId = Get-ContainerIdByImage -ContainerName "platform"
    if ([string]::IsNullOrEmpty($ContainerId)) {
        Write-Error "Could not find container with 'platform' image. Please provide ContainerId parameter or ensure the platform container is running."
        exit 1
    }
}

. $watchUrlScriptPath

$appAuthUrl = "$ApiUrl/connect/token"
$checkModulesUrl = "$ApiUrl/api/platform/modules"

. "$PSScriptRoot/auth-helper.ps1"

function Watch-Url-Up {
    param 
    (
        [string]$ApiUrl = "http://localhost:8090", # Host URL
        [int]$TimeoutMinutes = 1, # Max period of time for retry attempts in minutes
        [int]$RetrySeconds = 1, # Period of time between retry attempts in seconds
        [int]$WaitSeconds = 6, # Period of time before start retry attempts in seconds
        [string]$ContainerId = "virtocommerce-vc-platform-web-1" # $ContainerId to write host container log on each 3 unsuccess attempt
    )

    $printLogAttempt = 3
    $restartContainerAttempt = 9

    $responseStatus = 0
    [int]$maxRepeat = $TimeoutMinutes * 60 / $RetrySeconds


    Write-Host "`e[33mWait before $ApiUrl check status attempts for $WaitSeconds seconds."
    Start-Sleep -s $WaitSeconds

    $attempt = 1
    $responseStatus = 0
    do {
        Write-Host "`e[33mTry to open $ApiUrl. Attempt # $attempt of $maxRepeat."
        try {
            $response = Invoke-WebRequest $ApiUrl -Method Get
            $responseStatus = [int] $response.StatusCode
        }
        catch {
            if ($attempt % $printLogAttempt -eq 0) {
                Write-Host "Current $ContainerId container log is:"
                $logs = ''
                
                $logs = docker logs $ContainerId 2>&1
                if ($logs -match 'Unhandled exception.*') {
                    Write-Error "An unhandled exception found: $($matches[0])"
                    $logs
                    exit 1
                }
                else {
                    $logs
                }
            }
            if ($attempt % $restartContainerAttempt -eq 0) {
                Write-Host "`e[31mForce to restart container $ContainerId"
                docker restart $ContainerId
            }
            if ($maxRepeat -gt $attempt) {
                Start-Sleep -s $RetrySeconds
            }
            $attempt ++
        }
    } until ($responseStatus -eq 200 -or $maxRepeat -lt $attempt)

    if ($responseStatus -eq 200) {
        Write-Host "`e[32m$ApiUrl is up!"
        $result = $true
    }
    else {
        Write-Host "`e[31m$ApiUrl may be down, please check!"
        $result = $false
    }

    return $result
}

$platformIsUp = (Watch-Url-Up -ApiUrl $ApiUrl -TimeoutMinutes 15 -RetrySeconds 15 -WaitSeconds 15 -ContainerId $ContainerId)

if (-not $platformIsUp) {
    Write-Host "Error: Platform at $ApiUrl did not become available in time." -ForegroundColor Red
    exit 1
}

$authToken = Get-AuthToken $appAuthUrl $Username $Password
if ([string]::IsNullOrWhiteSpace($authToken)) {
    Write-Host "Error: auth token is empty after Get-AuthToken." -ForegroundColor Red
    exit 1
}

$headers = @{}
$headers.Add("Authorization", "Bearer $authToken")
try {
    $modules = Invoke-RestMethod $checkModulesUrl -Method Get -Headers $headers -SkipCertificateCheck -MaximumRetryCount 5 -RetryIntervalSec 5
}
catch {
    Write-Host "Error: Failed to check modules status at $checkModulesUrl" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
$installedModules = 0
if ($modules.Length -le 0) {
    Write-Host "Error: No module info returned from $checkModulesUrl" -ForegroundColor Red
    exit 1
}
Foreach ($module in $modules) {
    if ($module.isInstalled) {
        Write-Host "`e[32m$($module.id) version $($module.version) is installed"
        $installedModules++
    }
    if ($module.validationErrors.Length -gt 0) {
        Write-Host "Error: Module $($module.id) has validation errors:" -ForegroundColor Red
        Write-Output $module.validationErrors
        exit 1
    }
}
Write-Output "Modules installed: $installedModules"
if ($installedModules -lt $MinInstalledModules) {
    Write-Host "Error: Expected at least $MinInstalledModules installed modules, found $installedModules." -ForegroundColor Red
    exit 1
}

