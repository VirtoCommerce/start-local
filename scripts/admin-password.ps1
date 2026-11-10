# Admin sign-in and password helpers (DEC C1). The platform seeds admin / store.

function Get-AdminLoginCandidates {
    # The passwords to try for admin, in order: the configured one (when set), then the seeded one.
    param (
        [Parameter(Position = 0)]
        [string]$AdminPassword
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($AdminPassword)) {
        $candidates.Add($AdminPassword)
    }
    if ($candidates -cnotcontains 'store') {
        $candidates.Add('store')
    }
    return , [string[]]$candidates.ToArray()
}

function Get-AdminToken {
    # Signs in as admin with the first working candidate. Returns $null when none works.
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$ApiUrl,
        [Parameter(Position = 1)]
        [string]$AdminPassword
    )

    foreach ($candidate in (Get-AdminLoginCandidates -AdminPassword $AdminPassword)) {
        $token = Get-AuthToken -AppAuthUrl "$ApiUrl/connect/token" -Username 'admin' -Password $candidate
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            return $token
        }
    }
    return $null
}

function Set-AdminPassword {
    # Sets the admin password through the API and clears the forced change on the next sign-in.
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$ApiUrl,
        [Parameter(Mandatory, Position = 1)]
        [string]$Token,
        [Parameter(Mandatory, Position = 2)]
        [string]$NewPassword
    )

    $resetUrl = "$ApiUrl/api/platform/security/users/admin/resetpassword"
    $resetBody = @{ newPassword = $NewPassword; forcePasswordChangeOnNextSignIn = $false } | ConvertTo-Json
    try {
        $result = Invoke-RestMethod -Uri $resetUrl -Method Post -ContentType 'application/json' -Body $resetBody -Headers @{ Authorization = "Bearer $Token" } -SkipCertificateCheck
    }
    catch {
        Write-Warning "Failed to reset the admin password at ${resetUrl}: $($_.Exception.Message)"
        return $false
    }
    if (-not $result.succeeded) {
        Write-Warning "The platform rejected the admin password: $($result.errors | ConvertTo-Json -Compress)"
        return $false
    }
    return $true
}
