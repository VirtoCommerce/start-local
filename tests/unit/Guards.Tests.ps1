# Defined outside BeforeAll: Pester reads -ForEach data at discovery time.
$guards = @(
    @{ Old = 'build-VC-solution.ps1'; New = 'build.ps1' }
    @{ Old = 'start-VC-solution.ps1'; New = 'start.ps1' }
    @{ Old = 'stop-VC-solution.ps1'; New = 'stop.ps1' }
    @{ Old = 'remove-VC-solution.ps1'; New = 'remove.ps1' }
)

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    # Copies the guard alone into a fresh folder and runs it. Writes a .env only when -EnvText is passed:
    # a [string] parameter turns $null into '', so "was it passed" is read from $PSBoundParameters.
    function script:Invoke-Guard {
        param([string]$Old, [string[]]$Arguments, [string]$EnvText)
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $folder
        Copy-Item -LiteralPath (Join-Path (Get-TestRepositoryRoot) $Old) -Destination $folder
        if ($PSBoundParameters.ContainsKey('EnvText')) {
            Set-Content -LiteralPath (Join-Path $folder '.env') -Value $EnvText
        }
        $envExisted = Test-Path -LiteralPath (Join-Path $folder '.env')
        $output = & pwsh -NoProfile -File (Join-Path $folder $Old) @Arguments *>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; EnvExisted = $envExisted }
    }

    $script:Arguments = @('-targetFolder', 'X', '-skipSampleData', '$false')
}

Describe 'Old-name guards' -Tag 'Unit' {
    Context '<Old>' -ForEach $guards {
        It 'explains the old layout and the installer when there is no .env' {
            $result = Invoke-Guard -Old $Old -Arguments $script:Arguments
            $result.EnvExisted | Should -BeFalse
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'release/1\.0'
            $result.Output | Should -Match 'install\.ps1'
            $result.Output | Should -Match 'passwords'
        }

        It 'explains the old layout and the installer for a layout 1 .env' {
            $result = Invoke-Guard -Old $Old -Arguments $script:Arguments -EnvText "DB_PROVIDER=postgres`nDB_PASSWORD=secret"
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'release/1\.0'
            $result.Output | Should -Match 'VirtoLocal_create_local_files\.ps1'
            $result.Output | Should -Match '-branch release/1\.0'
            $result.Output | Should -Match 'install\.ps1'
            $result.Output | Should -Match 'passwords'
        }

        It 'says the script is renamed and exits 1 when START_LOCAL_LAYOUT=2' {
            $result = Invoke-Guard -Old $Old -Arguments $script:Arguments -EnvText "START_LOCAL_LAYOUT=2`nCOMPOSE_FILE=docker-compose.yml"
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'renamed'
            $result.Output | Should -Match ([regex]::Escape($New))
        }

        It 'never fails to bind <Label>' -ForEach @(
            @{ Label = 'no arguments'; Arguments = @() }
            @{ Label = 'old installer arguments'; Arguments = @('-targetFolder', 'X', '-skipSampleData', '$false') }
            @{ Label = 'named and switch arguments'; Arguments = @('-solutionFolder', 'Y', '-dbProvider', 'mysql', '-allowInsecureHttp', '-vcSolutionVersion', 'edge') }
            @{ Label = 'positional arguments'; Arguments = @('one', 'two', '3') }
        ) {
            foreach ($envText in $null, "DB_PROVIDER=mysql", "START_LOCAL_LAYOUT=2") {
                $envArguments = if ($null -eq $envText) { @{} } else { @{ EnvText = $envText } }
                $result = Invoke-Guard -Old $Old -Arguments $Arguments @envArguments
                $result.Output | Should -Not -Match 'positional parameter|parameter cannot be found|ParameterBindingException|ambiguous'
                $result.Output | Should -Match 'release/1\.0|renamed'
            }
        }
    }
}

# The four guards must stay standalone (they dot-source nothing), so the shared body is copied; this catches drift.
Describe 'Old-name guard bodies' -Tag 'Unit' {
    BeforeAll {
        function script:Get-NormalizedGuard {
            param([string]$Name)
            $text = Get-Content -LiteralPath (Join-Path (Get-TestRepositoryRoot) $Name) -Raw
            ($text -replace '\r\n', "`n") -replace "(?m)^[$]newName = '[^']*'", '$newName = <name>'
        }
    }

    It '<Old> equals build-VC-solution.ps1 apart from the new name' -ForEach $guards {
        $reference = Get-NormalizedGuard -Name 'build-VC-solution.ps1'
        $reference | Should -Match '\$newName = <name>'
        Get-NormalizedGuard -Name $Old | Should -BeExactly $reference
    }
}
