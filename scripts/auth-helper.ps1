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
