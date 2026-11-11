BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    # A solution folder in TestDrive: the payload, plus a .env for a Docker platform in HTTP mode.
    function script:New-StartFolder {
        param([string]$AdminPassword)
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Payload -Root (Get-TestRepositoryRoot) -Destination $folder
        $document = Read-EnvFile (Join-Path $folder '.env.example')
        Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value 'docker-compose.yml;docker-compose.postgres.yml;docker-compose.platform.yml;docker-compose.platform-postgres.yml'
        Set-EnvValue -Document $document -Key 'RELEASE_CHANNEL' -Value 'stable'
        if ($AdminPassword) {
            Set-EnvValue -Document $document -Key 'ADMIN_PASSWORD' -Value $AdminPassword
        }
        $null = Update-EnvSecrets -Document $document -SecretKeys $script:SecretKeys
        Write-EnvFile -Document $document -Path (Join-Path $folder '.env')
        $folder
    }

    # A fake platform behind the API calls of start.ps1: admin signs in with $global:StartTestPlatform.Password only (a global: mock bodies run outside this script scope).
    function script:Mock-Platform {
        $global:StartTestPlatform = @{ Password = 'store' }
        Mock Invoke-Preflight { }
        Mock Invoke-DockerCompose { $global:LASTEXITCODE = 0 }
        Mock Watch-Url-Up { $true }
        Mock Start-Sleep { }
        Mock Get-AuthToken { if ($Password -ceq $global:StartTestPlatform.Password) { 'tok' } else { $null } }
        Mock Invoke-RestMethod { 1..23 | ForEach-Object { [pscustomobject]@{ id = "Module$_"; version = '3.0.0'; isInstalled = $true; validationErrors = @() } } } -ParameterFilter { "$Uri" -like '*/api/platform/modules' }
        Mock Invoke-RestMethod {
            $global:StartTestPlatform.Password = ($Body | ConvertFrom-Json).newPassword
            [pscustomobject]@{ succeeded = $true }
        } -ParameterFilter { "$Uri" -like '*/users/admin/resetpassword' }
        # The sample data's Users section updates the admin with its own password hash, the seeded one.
        Mock Invoke-RestMethod {
            $global:StartTestPlatform.Password = 'store'
            [pscustomobject]@{ id = 'notification-1' }
        } -ParameterFilter { "$Uri" -like '*/sampledata/autoinstall' }
        Mock Invoke-RestMethod { [pscustomobject]@{ notifyEvents = [pscustomobject]@{ errorCount = 0; finished = '2026-11-10T00:00:00Z' } } } -ParameterFilter { "$Uri" -like '*/pushnotifications' }
    }

    function script:Invoke-Start {
        param([Parameter(Mandatory)][string]$Folder, [bool]$SkipSampleData)
        $global:LASTEXITCODE = 0
        $null = & (Join-Path $Folder 'start.ps1') -solutionFolder $Folder -nonInteractive -skipSampleData $SkipSampleData *>&1
        $LASTEXITCODE
    }
}

AfterAll {
    Remove-Variable -Name StartTestPlatform -Scope Global -ErrorAction Ignore
}

Describe 'Start' -Tag 'Unit' {
    Context 'admin password (C1)' {
        It 'leaves ADMIN_PASSWORD on the platform after the sample data import, which restores the seeded admin' {
            $folder = New-StartFolder
            Mock-Platform

            Invoke-Start -Folder $folder -SkipSampleData $false | Should -Be 0

            $adminPassword = Get-EnvValue -Document (Read-EnvFile (Join-Path $folder '.env')) -Key 'ADMIN_PASSWORD'
            $adminPassword | Should -Not -BeNullOrEmpty
            $global:StartTestPlatform.Password | Should -BeExactly $adminPassword
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { "$Uri" -like '*/sampledata/autoinstall' }
        }

        It 'keeps ADMIN_PASSWORD on a later start that skips the sample data' {
            $folder = New-StartFolder
            Mock-Platform

            Invoke-Start -Folder $folder -SkipSampleData $false | Should -Be 0
            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            $adminPassword = Get-EnvValue -Document (Read-EnvFile (Join-Path $folder '.env')) -Key 'ADMIN_PASSWORD'
            $global:StartTestPlatform.Password | Should -BeExactly $adminPassword
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { "$Uri" -like '*/sampledata/autoinstall' }
        }

        It 'restores a preset ADMIN_PASSWORD after the sample data import and bounds the refused sign-ins' {
            $preset = 'Preset-Admin-Pw-1'
            $folder = New-StartFolder -AdminPassword $preset
            Mock-Platform

            Invoke-Start -Folder $folder -SkipSampleData $false | Should -Be 0

            Get-EnvValue -Document (Read-EnvFile (Join-Path $folder '.env')) -Key 'ADMIN_PASSWORD' | Should -BeExactly $preset
            $global:StartTestPlatform.Password | Should -BeExactly $preset
            # The platform starts on the seeded password: the preset is refused by the modules check, the sample data and the reset, each then falls back to the seeded one.
            Should -Invoke Get-AuthToken -Times 3 -Exactly -ParameterFilter { $Password -ceq $preset }
            Should -Invoke Get-AuthToken -Times 3 -Exactly -ParameterFilter { $Password -ceq 'store' }
            Should -Invoke Get-AuthToken -Times 6 -Exactly
        }
    }
}
