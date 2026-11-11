BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:StableJson = Get-Content -Raw -Path "$PSScriptRoot/../fixtures/json/stable.json" | ConvertFrom-Json
}

Describe 'ReleaseChannel' -Tag 'Unit' {
    Context 'ConvertTo-ReleaseChannel' {
        It 'parses <Value>' -TestCases @(
            @{ Value = 'stable'; Kind = 'stable'; Number = $null; Normalized = 'stable' }
            @{ Value = 'stable:16'; Kind = 'stable-n'; Number = 16; Normalized = 'stable:16' }
            @{ Value = 'edge'; Kind = 'edge'; Number = $null; Normalized = 'edge' }
            @{ Value = 'custom'; Kind = 'custom'; Number = $null; Normalized = 'custom' }
        ) {
            $channel = ConvertTo-ReleaseChannel -Value $Value
            $channel.Kind | Should -Be $Kind
            $channel.Number | Should -Be $Number
            $channel.Normalized | Should -Be $Normalized
            @($channel.Warnings) | Should -HaveCount 0
        }

        It 'accepts latest-stable as stable with a rename warning' {
            $channel = ConvertTo-ReleaseChannel -Value 'latest-stable'
            $channel.Kind | Should -Be 'stable'
            $channel.Normalized | Should -Be 'stable'
            @($channel.Warnings) | Should -HaveCount 1
            $channel.Warnings[0] | Should -Match "renamed to 'stable'"
        }

        It 'rejects <Name>' -TestCases @(
            @{ Name = 'an unknown name'; Value = 'foo' }
            @{ Name = 'a missing number'; Value = 'stable:' }
            @{ Name = 'a non-numeric number'; Value = 'stable:x' }
            @{ Name = 'a negative number'; Value = 'stable:-1' }
            @{ Name = 'a number out of range'; Value = 'stable:99999999999' }
            @{ Name = 'an empty string'; Value = '' }
        ) {
            ConvertTo-ReleaseChannel -Value $Value | Should -BeNullOrEmpty
        }
    }

    Context 'Test-StableBundleKey' {
        It 'is <Expected> for <Number>' -TestCases @(
            @{ Number = 13; Expected = $false }
            @{ Number = 16; Expected = $true }
            @{ Number = 0; Expected = $true }
            @{ Number = 17; Expected = $false }
        ) {
            Test-StableBundleKey -Number $Number -StableJson $script:StableJson | Should -Be $Expected
        }
    }

    Context 'Get-VcBuildInstallArgs' {
        It 'builds the arguments for <Value>' -TestCases @(
            @{ Value = 'stable'; Head = @('install') }
            @{ Value = 'stable:16'; Head = @('install', '-v', '16') }
            @{ Value = 'edge'; Head = @('install', '-Edge') }
            @{ Value = 'custom'; Head = @('install', '--package-manifest-path', 'M') }
        ) {
            $channel = ConvertTo-ReleaseChannel -Value $Value
            $actual = Get-VcBuildInstallArgs -Channel $channel -ManifestPath 'M' -DiscoveryPath 'D' -ProbingPath 'P' -Root 'R'
            $tail = '--probing-path', 'P', '--discovery-path', 'D', '--root', 'R', '--skip-dependency-solving'
            $actual | Should -BeOfType [string]
            $actual | Should -Be ([string[]](@($Head) + $tail))
        }
    }

    Context 'Get-BundleSpec' {
        It 'resolves <Value>' -TestCases @(
            @{ Value = 'stable'; BundleKey = 'latest'; Edge = $false; FrontendSource = 'bundle' }
            @{ Value = 'stable:16'; BundleKey = '16'; Edge = $false; FrontendSource = 'bundle' }
            @{ Value = 'edge'; BundleKey = $null; Edge = $true; FrontendSource = 'latest-release' }
            @{ Value = 'custom'; BundleKey = $null; Edge = $false; FrontendSource = 'custom' }
        ) {
            $spec = Get-BundleSpec -Channel (ConvertTo-ReleaseChannel -Value $Value)
            $spec.BundleKey | Should -Be $BundleKey
            $spec.Edge | Should -Be $Edge
            $spec.FrontendSource | Should -Be $FrontendSource
        }
    }
}
