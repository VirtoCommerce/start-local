BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'Compose helper' -Tag 'Unit' {
    Context 'Test-ComposeVersion' {
        It 'accepts <Version> against the default minimum: <Expected>' -TestCases @(
            @{ Version = '2.18.0'; Expected = $true }
            @{ Version = '2.17.3'; Expected = $false }
            @{ Version = 'v2.40.3'; Expected = $true }
            @{ Version = '5.6.0'; Expected = $true }
            @{ Version = '2.18.0-desktop.1'; Expected = $true }
        ) {
            Test-ComposeVersion -Version $Version | Should -Be $Expected
        }

        It 'takes the minimum from -Minimum' {
            Test-ComposeVersion '2.20.0' '2.21.0' | Should -BeFalse
            Test-ComposeVersion '2.21.0' '2.21.0' | Should -BeTrue
        }

        It 'compares numbers, not text (2.100.0 is newer than 2.18.0)' {
            Test-ComposeVersion '2.100.0' | Should -BeTrue
        }

        It 'treats text that is not a version as too old' {
            Test-ComposeVersion 'not-a-version' | Should -BeFalse
            Test-ComposeVersion '' | Should -BeFalse
        }
    }
}
