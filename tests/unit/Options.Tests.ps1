BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:ExamplePath = Join-Path $PSScriptRoot '../../.env.example'

    # A document of .env.example with COMPOSE_FILE set to a compose list (default: the postgres list, HTTPS on).
    function script:New-OptionsDocument {
        param(
            [string[]]$ComposeFiles = (Get-DefaultComposeFiles -Provider postgres),
            [hashtable]$Values = @{}
        )

        $document = Read-EnvFile -Path $script:ExamplePath
        Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value (ConvertTo-ComposeFileValue $ComposeFiles)
        foreach ($key in $Values.Keys) {
            Set-EnvValue -Document $document -Key $key -Value $Values[$key]
        }
        $document
    }

    function script:Get-DocumentComposeFiles {
        param($Document)
        $files = Get-ComposeFileList (Get-EnvValue -Document $Document -Key 'COMPOSE_FILE')
        $files
    }
}

Describe 'Options' -Tag 'Unit' {
    Context 'Update-EnvFromOptions: COMPOSE_FILE switches' {
        It '-dbProvider mysql swaps the provider and its platform link' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ dbProvider = 'mysql' }
            $files = Get-DocumentComposeFiles $document
            $files | Should -Not -Contain 'docker-compose.postgres.yml'
            $files | Should -Not -Contain 'docker-compose.platform-postgres.yml'
            $files | Should -Contain 'docker-compose.mysql.yml'
            $files | Should -Contain 'docker-compose.platform-mysql.yml'
        }

        It '-dbProvider on an empty COMPOSE_FILE starts from the default list of that provider' {
            $document = Read-EnvFile -Path $script:ExamplePath
            $null = Update-EnvFromOptions -Document $document -Bound @{ dbProvider = 'sqlserver' }
            Get-DocumentComposeFiles $document | Should -Be (Get-DefaultComposeFiles -Provider sqlserver)
        }

        It '-allowInsecureHttp removes every .https.yml and -allowInsecureHttp:$false restores them' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ allowInsecureHttp = [switch]$true }
            @(Get-DocumentComposeFiles $document | Where-Object { $_ -like '*.https.yml' }) | Should -HaveCount 0

            $null = Update-EnvFromOptions -Document $document -Bound @{ allowInsecureHttp = [switch]::new($false) }
            Get-DocumentComposeFiles $document | Should -Be (Get-DefaultComposeFiles -Provider postgres)
        }

        It 'FRONTEND_PORT follows the mode default: <Name>' -TestCases @(
            @{ Name = 'HTTPS 443 to HTTP'; Https = $true; Port = '443'; Insecure = $true; Expected = '80' }
            @{ Name = 'HTTP 80 to HTTPS'; Https = $false; Port = '80'; Insecure = $false; Expected = '443' }
            @{ Name = 'HTTPS 8443 to HTTP keeps the custom port'; Https = $true; Port = '8443'; Insecure = $true; Expected = '8443' }
            @{ Name = 'HTTP 80 with no mode change'; Https = $false; Port = '80'; Insecure = $true; Expected = '80' }
            @{ Name = 'HTTP 8080 to HTTPS keeps the custom port'; Https = $false; Port = '8080'; Insecure = $false; Expected = '8080' }
        ) {
            $document = New-OptionsDocument -ComposeFiles (Get-DefaultComposeFiles -Provider postgres -Https $Https) -Values @{ FRONTEND_PORT = $Port }
            $null = Update-EnvFromOptions -Document $document -Bound @{ allowInsecureHttp = [switch]::new($Insecure) }
            Get-EnvValue -Document $document -Key 'FRONTEND_PORT' | Should -Be $Expected
        }

        It '-skipKibana removes the four Kibana files and -skipKibana:$false restores them' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ skipKibana = [switch]$true }
            $files = Get-DocumentComposeFiles $document
            foreach ($name in 'kibana.yml', 'kibana.https.yml', 'kibana-elasticsearch.yml', 'kibana-elasticsearch.https.yml') {
                $files | Should -Not -Contain "docker-compose.$name"
            }

            $null = Update-EnvFromOptions -Document $document -Bound @{ skipKibana = [switch]::new($false) }
            Get-DocumentComposeFiles $document | Should -Be (Get-DefaultComposeFiles -Provider postgres)
        }

        It '-skip<Part> removes the part and its files: <Switch>' -TestCases @(
            @{ Switch = 'skipFrontend'; Removed = 'docker-compose.frontend.yml' }
            @{ Switch = 'skipElasticsearch'; Removed = 'docker-compose.elasticsearch.yml' }
            @{ Switch = 'skipRedis'; Removed = 'docker-compose.redis.yml' }
        ) {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ $Switch = [switch]$true } -WarningAction SilentlyContinue
            Get-DocumentComposeFiles $document | Should -Not -Contain $Removed
        }

        It '-skipElasticsearch drops Kibana with a warning' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ skipElasticsearch = [switch]$true } -WarningVariable dropped -WarningAction SilentlyContinue
            $dropped | Should -Match 'docker-compose.kibana.yml needs docker-compose.elasticsearch.yml'
            Get-DocumentComposeFiles $document | Should -Not -Contain 'docker-compose.kibana.yml'
        }

        It '-skipPlatform with PLATFORM_SOURCE_PATH writes SKIP_PLATFORM and keeps COMPOSE_FILE' {
            $document = New-OptionsDocument -Values @{ PLATFORM_SOURCE_PATH = '/src/p' }
            $before = Get-EnvValue -Document $document -Key 'COMPOSE_FILE'
            $null = Update-EnvFromOptions -Document $document -Bound @{ skipPlatform = [switch]$true }
            Get-EnvValue -Document $document -Key 'SKIP_PLATFORM' | Should -Be 'true'
            Get-EnvValue -Document $document -Key 'COMPOSE_FILE' | Should -Be $before

            $null = Update-EnvFromOptions -Document $document -Bound @{ skipPlatform = [switch]::new($false) }
            Get-EnvValue -Document $document -Key 'SKIP_PLATFORM' | Should -BeNullOrEmpty
        }

        It '-skipPlatform without PLATFORM_SOURCE_PATH removes the platform files and adds the host-platform link' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ skipPlatform = [switch]$true }
            $files = Get-DocumentComposeFiles $document
            @($files | Where-Object { $_ -like 'docker-compose.platform*' }) | Should -HaveCount 0
            $files | Should -Contain 'docker-compose.frontend-hostplatform.yml'
            Get-EnvValue -Document $document -Key 'SKIP_PLATFORM' | Should -BeNullOrEmpty
        }

        It 'warns and leaves COMPOSE_FILE empty when a switch needs a list but there is none' {
            $document = Read-EnvFile -Path $script:ExamplePath
            $warnings = Update-EnvFromOptions -Document $document -Bound @{ skipKibana = [switch]$true }
            $warnings.Count | Should -Be 1
            $warnings[0] | Should -Match 'COMPOSE_FILE'
            Get-EnvValue -Document $document -Key 'COMPOSE_FILE' | Should -BeNullOrEmpty
        }
    }

    Context 'Update-EnvFromOptions: real $PSBoundParameters' {
        BeforeAll {
            # What an entry script does: declare the parameters and hand $PSBoundParameters over.
            function script:Invoke-LikeAnEntryScript {
                param([string]$dbProvider, [switch]$allowInsecureHttp, [switch]$skipKibana, [switch]$skipSampleData, $Document)
                Update-EnvFromOptions -Document $Document -Bound $PSBoundParameters
            }
        }

        It 'applies the switches the caller passed and ignores the others' {
            $document = New-OptionsDocument
            $null = Invoke-LikeAnEntryScript -dbProvider MySQL -allowInsecureHttp -skipKibana -skipSampleData -Document $document
            $files = Get-DocumentComposeFiles $document
            $files | Should -Contain 'docker-compose.mysql.yml'
            @($files | Where-Object { $_ -like '*.https.yml' -or $_ -like '*kibana*' }) | Should -HaveCount 0
            Get-EnvValue -Document $document -Key 'FRONTEND_PORT' | Should -Be '80'
        }

        It 'undoes a switch passed as :$false' {
            $document = New-OptionsDocument -ComposeFiles (Get-DefaultComposeFiles -Provider postgres -Https $false) -Values @{ FRONTEND_PORT = '80' }
            $null = Invoke-LikeAnEntryScript -allowInsecureHttp:$false -Document $document
            Get-DocumentComposeFiles $document | Should -Be (Get-DefaultComposeFiles -Provider postgres -Https $true)
            Get-EnvValue -Document $document -Key 'FRONTEND_PORT' | Should -Be '443'
        }
    }

    Context 'Update-EnvFromOptions: values' {
        It '-releaseChannel latest-stable writes stable and returns one warning' {
            $document = New-OptionsDocument
            $warnings = Update-EnvFromOptions -Document $document -Bound @{ releaseChannel = 'latest-stable' }
            Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL' | Should -Be 'stable'
            $warnings.Count | Should -Be 1
        }

        It '-releaseChannel stable:16 is written normalized, without warnings' {
            $document = New-OptionsDocument
            $warnings = Update-EnvFromOptions -Document $document -Bound @{ releaseChannel = ' Stable:16 ' }
            Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL' | Should -Be 'stable:16'
            $warnings.Count | Should -Be 0
        }

        It '-releaseChannel with an unknown value throws naming it' {
            $document = New-OptionsDocument
            { Update-EnvFromOptions -Document $document -Bound @{ releaseChannel = 'nightly' } } |
                Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage "*nightly*"
        }

        It '-vcSolutionVersion edge writes RELEASE_CHANNEL=edge' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ vcSolutionVersion = 'edge' }
            Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL' | Should -Be 'edge'
        }

        It '-releaseChannel wins over -vcSolutionVersion' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ vcSolutionVersion = 'edge'; releaseChannel = 'stable' }
            Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL' | Should -Be 'stable'
        }

        It '-elasticsearchVersion 9.1.0 writes STACK_VERSION' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ elasticsearchVersion = '9.1.0' }
            Get-EnvValue -Document $document -Key 'STACK_VERSION' | Should -Be '9.1.0'
        }

        It '-branch release/2.0 writes START_LOCAL_REF' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ branch = 'release/2.0' }
            Get-EnvValue -Document $document -Key 'START_LOCAL_REF' | Should -Be 'release/2.0'
        }

        It '-customPackagesJson and -customFrontendUrl write their keys' {
            $document = New-OptionsDocument
            $null = Update-EnvFromOptions -Document $document -Bound @{ customPackagesJson = 'https://example.com/m.json'; customFrontendUrl = '/tmp/front.zip' }
            Get-EnvValue -Document $document -Key 'CUSTOM_PACKAGES_JSON' | Should -Be 'https://example.com/m.json'
            Get-EnvValue -Document $document -Key 'CUSTOM_FRONTEND_URL' | Should -Be '/tmp/front.zip'
        }

        It 'per-run switches never persist' {
            $document = New-OptionsDocument
            $before = ConvertTo-EnvText -Document $document
            $warnings = Update-EnvFromOptions -Document $document -Bound @{
                skipSampleData = $true
                nonInteractive = [switch]$true
                keepData       = [switch]$true
                solutionFolder = '/some/folder'
            }
            ConvertTo-EnvText -Document $document | Should -Be $before
            $warnings.Count | Should -Be 0
        }

        It 'changes nothing when no parameter is bound' {
            $document = New-OptionsDocument
            $before = ConvertTo-EnvText -Document $document
            $null = Update-EnvFromOptions -Document $document -Bound @{}
            ConvertTo-EnvText -Document $document | Should -Be $before
        }
    }

    Context 'Test-NonInteractive' {
        It 'switch=<Switch> redirected=<Redirected> CI=<Ci> is <Expected>' -TestCases @(
            @{ Switch = $false; Redirected = $false; Ci = ''; Expected = $false }
            @{ Switch = $true; Redirected = $false; Ci = ''; Expected = $true }
            @{ Switch = $false; Redirected = $true; Ci = ''; Expected = $true }
            @{ Switch = $false; Redirected = $false; Ci = 'true'; Expected = $true }
            @{ Switch = $false; Redirected = $false; Ci = 'TRUE'; Expected = $true }
            @{ Switch = $false; Redirected = $false; Ci = 'false'; Expected = $false }
        ) {
            Test-NonInteractive -Switch $Switch -InputRedirected $Redirected -CiValue $Ci | Should -Be $Expected
        }
    }

    Context 'Get-MissingRequiredKeys' {
        It 'reports COMPOSE_FILE and RELEASE_CHANNEL for .env.example' {
            $document = Read-EnvFile -Path $script:ExamplePath
            $missing = Get-MissingRequiredKeys -EnvValues (Get-EnvTable -Document $document)
            $missing | Should -Be @('COMPOSE_FILE', 'RELEASE_CHANNEL')
        }

        It 'adds CUSTOM_PACKAGES_JSON for the custom channel' {
            $document = New-OptionsDocument -Values @{ RELEASE_CHANNEL = 'custom' }
            $missing = Get-MissingRequiredKeys -EnvValues (Get-EnvTable -Document $document)
            $missing | Should -Be @('CUSTOM_PACKAGES_JSON')
        }

        It 'reports nothing once every required key is set' {
            $document = New-OptionsDocument -Values @{ RELEASE_CHANNEL = 'custom'; CUSTOM_PACKAGES_JSON = '/m.json' }
            $missing = Get-MissingRequiredKeys -EnvValues (Get-EnvTable -Document $document)
            $missing.Count | Should -Be 0
        }

        It 'treats absent keys as empty' {
            $missing = Get-MissingRequiredKeys -EnvValues @{}
            $missing | Should -Be @('COMPOSE_FILE', 'RELEASE_CHANNEL')
        }
    }

    Context 'Request-RequiredEnvKeys' {
        BeforeEach {
            $script:Answers = [System.Collections.Generic.Queue[string]]::new()
            Mock Read-Host { $script:Answers.Dequeue() }
        }

        It 'returns the missing keys without prompting when non-interactive' {
            $document = Read-EnvFile -Path $script:ExamplePath
            $before = ConvertTo-EnvText -Document $document
            $stillMissing = Request-RequiredEnvKeys -Document $document -NonInteractive $true
            $stillMissing | Should -Be @('COMPOSE_FILE', 'RELEASE_CHANNEL')
            Should -Invoke Read-Host -Times 0 -Exactly
            ConvertTo-EnvText -Document $document | Should -Be $before
        }

        It 'takes the defaults on empty answers: postgres with HTTPS, stable' {
            $document = Read-EnvFile -Path $script:ExamplePath
            $script:Answers.Enqueue('')
            $script:Answers.Enqueue('')
            $stillMissing = Request-RequiredEnvKeys -Document $document -NonInteractive $false
            $stillMissing.Count | Should -Be 0
            Should -Invoke Read-Host -Times 2 -Exactly
            Get-DocumentComposeFiles $document | Should -Be (Get-DefaultComposeFiles -Provider postgres -Https $true)
            Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL' | Should -Be 'stable'
        }

        It 'maps the DB provider choice <Choice> to <Provider>' -TestCases @(
            @{ Choice = '1'; Provider = 'postgres' }
            @{ Choice = '2'; Provider = 'mysql' }
            @{ Choice = '3'; Provider = 'sqlserver' }
        ) {
            $document = Read-EnvFile -Path $script:ExamplePath
            Set-EnvValue -Document $document -Key 'RELEASE_CHANNEL' -Value 'edge'
            $script:Answers.Enqueue($Choice)
            $stillMissing = Request-RequiredEnvKeys -Document $document -NonInteractive $false
            $stillMissing.Count | Should -Be 0
            Get-DocumentComposeFiles $document | Should -Be (Get-DefaultComposeFiles -Provider $Provider -Https $true)
        }

        It 'asks once per key and returns the keys that stay missing' {
            $document = Read-EnvFile -Path $script:ExamplePath
            $script:Answers.Enqueue('9')
            $script:Answers.Enqueue('nightly')
            $stillMissing = Request-RequiredEnvKeys -Document $document -NonInteractive $false -WarningVariable rejected -WarningAction SilentlyContinue
            $stillMissing | Should -Be @('COMPOSE_FILE', 'RELEASE_CHANNEL')
            $rejected | Should -HaveCount 2
            Should -Invoke Read-Host -Times 2 -Exactly
        }

        It 'asks for CUSTOM_PACKAGES_JSON right after the custom channel is chosen' {
            $document = New-OptionsDocument
            $script:Answers.Enqueue('custom')
            $script:Answers.Enqueue('/manifests/m.json')
            $stillMissing = Request-RequiredEnvKeys -Document $document -NonInteractive $false
            $stillMissing.Count | Should -Be 0
            Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL' | Should -Be 'custom'
            Get-EnvValue -Document $document -Key 'CUSTOM_PACKAGES_JSON' | Should -Be '/manifests/m.json'
        }

        It 'returns CUSTOM_PACKAGES_JSON when its answer is empty' {
            $document = New-OptionsDocument -Values @{ RELEASE_CHANNEL = 'custom' }
            $script:Answers.Enqueue('')
            $stillMissing = Request-RequiredEnvKeys -Document $document -NonInteractive $false
            $stillMissing | Should -Be @('CUSTOM_PACKAGES_JSON')
        }

        It 'does not prompt when nothing is missing' {
            $document = New-OptionsDocument -Values @{ RELEASE_CHANNEL = 'stable' }
            $stillMissing = Request-RequiredEnvKeys -Document $document -NonInteractive $false
            $stillMissing.Count | Should -Be 0
            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }

    Context 'Read-YesNo' {
        BeforeEach {
            $script:Answers = [System.Collections.Generic.Queue[string]]::new()
            Mock Read-Host { $script:Answers.Dequeue() }
        }

        It 'returns the default without prompting when non-interactive' {
            Read-YesNo -Prompt 'Build now?' -Default $true -NonInteractive $true | Should -BeTrue
            Read-YesNo -Prompt 'Update vc-build?' -Default $false -NonInteractive $true | Should -BeFalse
            Should -Invoke Read-Host -Times 0 -Exactly
        }

        It 'answer <Answer> with default <Default> is <Expected>' -TestCases @(
            @{ Answer = ''; Default = $true; Expected = $true }
            @{ Answer = ''; Default = $false; Expected = $false }
            @{ Answer = 'y'; Default = $false; Expected = $true }
            @{ Answer = 'YES'; Default = $false; Expected = $true }
            @{ Answer = 'n'; Default = $true; Expected = $false }
            @{ Answer = 'No'; Default = $true; Expected = $false }
            @{ Answer = 'maybe'; Default = $true; Expected = $true }
        ) {
            $script:Answers.Enqueue($Answer)
            Read-YesNo -Prompt 'Build now?' -Default $Default -NonInteractive $false | Should -Be $Expected
        }
    }
}
