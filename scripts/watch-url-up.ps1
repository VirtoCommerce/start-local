function Watch-Url-Up {
    # Polls $ApiUrl until it answers 200. Returns $false when it does not within the timeout.
    # $OnFailureLog (for example { docker compose logs --tail 50 vc-platform-web }) runs on every third failed attempt.
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$ApiUrl,
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TimeoutMinutes = 15, # Max period of time for retry attempts in minutes
        [ValidateRange(1, [int]::MaxValue)]
        [int]$RetrySeconds = 15, # Period of time between retry attempts in seconds
        [ValidateRange(0, [int]::MaxValue)]
        [int]$WaitSeconds = 6, # Period of time before the first attempt in seconds
        [scriptblock]$OnFailureLog
    )

    $printLogAttempt = 3
    [int]$maxRepeat = [Math]::Max(1, [Math]::Floor($TimeoutMinutes * 60 / $RetrySeconds))

    Write-Host "Wait $WaitSeconds seconds before the $ApiUrl status checks." -ForegroundColor Yellow
    Start-Sleep -Seconds $WaitSeconds

    for ($attempt = 1; $attempt -le $maxRepeat; $attempt++) {
        Write-Host "Try to open $ApiUrl. Attempt # $attempt of $maxRepeat." -ForegroundColor Yellow
        try {
            $response = Invoke-WebRequest -Uri $ApiUrl -Method Get -SkipCertificateCheck
            if ([int]$response.StatusCode -eq 200) {
                Write-Host "$ApiUrl is up!" -ForegroundColor Green
                return $true
            }
        }
        catch {
            if ($OnFailureLog -and $attempt % $printLogAttempt -eq 0) {
                & $OnFailureLog | Out-Host
            }
        }
        if ($attempt -lt $maxRepeat) {
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    Write-Host "$ApiUrl may be down, please check!" -ForegroundColor Red
    return $false
}
