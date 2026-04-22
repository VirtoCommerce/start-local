Param(
    [parameter(Mandatory = $true)]
    $ApiUrl,
    $SampleDataSrc,
    $Username = "admin",
    $Password = "store"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/auth-helper.ps1"

$sdStateUrl = "$ApiUrl/api/platform/pushnotifications"
if ([string]::IsNullOrWhiteSpace($SampleDataSrc)) {
    $sdInstallUrl = "$ApiUrl/api/platform/sampledata/autoinstall"
}
else {
    $sdInstallUrl = "$ApiUrl/api/platform/sampledata/import?url=$SampleDataSrc"
}
$appAuthUrl = "$ApiUrl/connect/token"

$authToken = Get-AuthToken $appAuthUrl $Username $Password
if ([string]::IsNullOrWhiteSpace($authToken)) {
    Write-Host "Error: auth token is empty after Get-AuthToken." -ForegroundColor Red
    exit 1
}

$headers = @{}
$headers.Add("Authorization", "Bearer $authToken")

try {
    $installResult = Invoke-RestMethod -Uri $sdInstallUrl -ContentType "application/json" -Method Post -Headers $headers -SkipCertificateCheck -MaximumRetryCount 5 -RetryIntervalSec 5
}
catch {
    Write-Host "Error: Failed to start sample data installation at $sdInstallUrl" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
Write-Output $installResult

$notificationId = $installResult.id
$NotificationStateJson = @"
     {"Ids":["$notificationId"],"start":0, "count": 1}
"@

$notify = @{}
$cycleCount = 0
$maxCycles = 180   # 180 * 3s sleep ≈ 9 minutes
do {
    Start-Sleep -s 3
    try {
        $state = Invoke-RestMethod "$sdStateUrl" -Body $NotificationStateJson -Method Post -ContentType "application/json" -Headers $headers -SkipCertificateCheck
    }
    catch {
        Write-Host "Error: Failed to query sample data installation state at $sdStateUrl" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
    Write-Output $state
    if ($state.notifyEvents -ne $null ) {
        $notify = $state.notifyEvents
        if ($notify.errorCount -gt 0) {
            Write-Output $notify
            Write-Host "`e[31mSample data installation failed."
            exit 1
        }
    }
    $cycleCount++
}
while (([string]::IsNullOrEmpty($notify.finished)) -and $cycleCount -lt $maxCycles)

if ([string]::IsNullOrEmpty($notify.finished)) {
    Write-Host "Error: Sample data installation did not complete within $($maxCycles * 3) seconds." -ForegroundColor Red
    exit 1
}
Write-Host "`e[32mSample data installation complete."
