Param(
    [parameter(Mandatory = $true)]
    $ApiUrl,
    $SampleDataSrc,
    $Username = "admin",
    $Password = "store"
)

$ErrorActionPreference = "Stop"

function Get-AuthToken {
    param (
        $appAuthUrl,
        $username,
        $password
    )
    Write-Host "Get-AuthToken: appAuthUrl $appAuthUrl"
    $grant_type = "password"
    $content_type = "application/x-www-form-urlencoded"

    $body = @{username = $username; password = $password; grant_type = $grant_type }
    try {
        $response = Invoke-WebRequest -Uri $appAuthUrl -Method Post -ContentType $content_type -Body $body -SkipCertificateCheck -MaximumRetryCount 5 -RetryIntervalSec 5
    }
    catch {
        Write-Host "Error: Failed to obtain auth token from $appAuthUrl" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }

    try {
        $responseContent = $response.Content | ConvertFrom-Json
    }
    catch {
        Write-Host "Error: Failed to parse auth response from $appAuthUrl" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($responseContent.access_token)) {
        Write-Host "Error: Auth response from $appAuthUrl did not contain an access_token." -ForegroundColor Red
        exit 1
    }

    return $responseContent.access_token
}

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
while (([string]::IsNullOrEmpty($notify.finished)) -and $cycleCount -lt 180)
Write-Host "`e[32mSample data installation complete."
