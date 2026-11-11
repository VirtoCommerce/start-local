function Get-AuthToken {
    # Returns the access token, or $null when the platform refuses the sign-in or cannot be reached.
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$AppAuthUrl,
        [Parameter(Mandatory, Position = 1)]
        [string]$Username,
        [Parameter(Mandatory, Position = 2)]
        [string]$Password
    )

    # No retries: Watch-Url-Up has already proven the platform reachable, and a refused (400) sign-in
    # must not be repeated, or the platform lockout could block the admin before the next candidate.
    $body = @{ username = $Username; password = $Password; grant_type = 'password' }
    try {
        $response = Invoke-WebRequest -Uri $AppAuthUrl -Method Post -ContentType 'application/x-www-form-urlencoded' -Body $body -SkipCertificateCheck
        $responseContent = $response.Content | ConvertFrom-Json
    }
    catch {
        Write-Verbose "Get-AuthToken: no token from ${AppAuthUrl}: $($_.Exception.Message)"
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($responseContent.access_token)) {
        Write-Verbose "Get-AuthToken: the response from $AppAuthUrl has no access_token."
        return $null
    }

    return [string]$responseContent.access_token
}
