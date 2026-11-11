BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    # A solution folder in TestDrive: the payload, plus a .env for a Docker platform in HTTP mode.
    function script:New-StartFolder {
        param([string]$AdminPassword, [string]$ModuleSourcePaths)
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Payload -Root (Get-TestRepositoryRoot) -Destination $folder
        $document = Read-EnvFile (Join-Path $folder '.env.example')
        Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value 'docker-compose.yml;docker-compose/postgres.yml;docker-compose/platform.yml;docker-compose/platform-postgres.yml'
        Set-EnvValue -Document $document -Key 'RELEASE_CHANNEL' -Value 'stable'
        if ($AdminPassword) {
            Set-EnvValue -Document $document -Key 'ADMIN_PASSWORD' -Value $AdminPassword
        }
        if ($ModuleSourcePaths) {
            Set-EnvValue -Document $document -Key 'MODULE_SOURCE_PATHS' -Value $ModuleSourcePaths
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
    Remove-Variable -Name StartTestPlatform, StartTestMissingFiles, StartTestLaunch -Scope Global -ErrorAction Ignore
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

    Context 'source modules in the Docker platform (P16)' {
        BeforeAll {
            function script:New-SourceModule {
                param([string]$ModuleId)
                $path = Join-Path $TestDrive "$ModuleId.Web"
                $null = New-Item -ItemType Directory -Path $path -Force
                Set-Content -LiteralPath (Join-Path $path 'module.manifest') -Value "<module><id>$ModuleId</id></module>"
                $path
            }
        }

        It 'writes the generated compose file, lists it in COMPOSE_FILE, and removes both when MODULE_SOURCE_PATHS is emptied' {
            $catalog = New-SourceModule 'VirtoCommerce.Catalog'
            $folder = New-StartFolder -ModuleSourcePaths $catalog
            $generated = Join-Path $folder 'docker-compose/platform-modules.yml'
            Mock-Platform

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            $generated | Should -Exist
            Get-Content -LiteralPath $generated -Raw | Should -BeLike '*/opt/virtocommerce/platform/modules/VirtoCommerce.Catalog*'
            (Get-EnvValue -Document (Read-EnvFile (Join-Path $folder '.env')) -Key 'COMPOSE_FILE') | Should -BeLike '*docker-compose/platform-modules.yml'

            $document = Read-EnvFile (Join-Path $folder '.env')
            Set-EnvValue -Document $document -Key 'MODULE_SOURCE_PATHS' -Value ''
            Write-EnvFile -Document $document -Path (Join-Path $folder '.env')

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            $generated | Should -Not -Exist
            (Get-EnvValue -Document (Read-EnvFile (Join-Path $folder '.env')) -Key 'COMPOSE_FILE') | Should -Not -BeLike '*platform-modules*'
        }

        It 'keeps every file listed in the on-disk COMPOSE_FILE until the preflight has passed' {
            $catalog = New-SourceModule 'VirtoCommerce.Catalog'
            $folder = New-StartFolder -ModuleSourcePaths $catalog
            $generated = Join-Path $folder 'docker-compose/platform-modules.yml'
            Mock-Platform
            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0
            $generated | Should -Exist

            $document = Read-EnvFile (Join-Path $folder '.env')
            Set-EnvValue -Document $document -Key 'MODULE_SOURCE_PATHS' -Value ''
            Write-EnvFile -Document $document -Path (Join-Path $folder '.env')
            $envBefore = Get-Content -LiteralPath (Join-Path $folder '.env') -Raw

            # While the preflight runs, .env still lists the generated file: Compose (ps, down) fails at project load when a listed file is missing.
            $global:StartTestMissingFiles = $null
            Mock Invoke-Preflight {
                $solution = (Get-Location).Path
                $listed = Get-ComposeFileList ([string](Get-EnvValue -Document (Read-EnvFile (Join-Path $solution '.env')) -Key 'COMPOSE_FILE')) ';'
                $global:StartTestMissingFiles = @($listed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $solution $_) -PathType Leaf) })
                'A port is already in use.'
            }

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 1

            $global:StartTestMissingFiles | Should -BeNullOrEmpty
            $generated | Should -Exist
            Get-Content -LiteralPath (Join-Path $folder '.env') -Raw | Should -BeExactly $envBefore
        }

        It 'writes no compose file when the platform is not a Docker platform' {
            $catalog = New-SourceModule 'VirtoCommerce.Catalog'
            $folder = New-StartFolder -ModuleSourcePaths $catalog
            $document = Read-EnvFile (Join-Path $folder '.env')
            Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value 'docker-compose.yml;docker-compose/postgres.yml'
            Write-EnvFile -Document $document -Path (Join-Path $folder '.env')
            Mock-Platform

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            (Join-Path $folder 'docker-compose/platform-modules.yml') | Should -Not -Exist
        }
    }

    Context 'platform from source (H3-H6, B6)' {
        BeforeAll {
            # A solution folder whose platform runs from source: no platform compose file, PLATFORM_SOURCE_PATH set.
            function script:New-SourceStartFolder {
                param([string]$PlatformPath, [hashtable]$Override = @{})
                $folder = New-StartFolder
                $document = Read-EnvFile (Join-Path $folder '.env')
                Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value 'docker-compose.yml;docker-compose/postgres.yml'
                Set-EnvValue -Document $document -Key 'PLATFORM_SOURCE_PATH' -Value $PlatformPath
                foreach ($key in $Override.Keys) {
                    Set-EnvValue -Document $document -Key $key -Value ([string]$Override[$key])
                }
                Write-EnvFile -Document $document -Path (Join-Path $folder '.env')
                $folder
            }

            function script:New-PrebuiltPlatform {
                $path = Join-Path $TestDrive "platform-$([guid]::NewGuid().ToString('N'))"
                $null = New-Item -ItemType Directory -Path $path
                Set-Content -LiteralPath (Join-Path $path 'VirtoCommerce.Platform.Web.dll') -Value 'x'
                $path
            }

            function script:Invoke-StartCapturing {
                param([string]$Folder)
                $global:LASTEXITCODE = 0
                $output = & (Join-Path $Folder 'start.ps1') -solutionFolder $Folder -nonInteractive -skipSampleData $true *>&1 | Out-String
                @{ ExitCode = $LASTEXITCODE; Output = $output }
            }
        }

        BeforeEach {
            Mock-Platform
            Mock Start-SourcePlatform { $global:StartTestLaunch = @{ Command = $Command; LogDir = $LogDir }; 4242 }
            Mock Stop-SourcePlatform { $false }
        }

        It 'writes the settings file into the platform folder, launches the platform from there, and checks it' {
            $platform = New-PrebuiltPlatform
            $folder = New-SourceStartFolder $platform

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            $settings = Get-Content -LiteralPath (Join-Path $platform 'VirtoCommerce.Platform.Web.settings.json') -Raw | ConvertFrom-Json
            $settings.ConnectionStrings.VirtoCommerce | Should -BeLike '*Host=localhost*'
            $settings.Kestrel.Endpoints.Main.Url | Should -Be 'http://127.0.0.1:8090'
            Should -Invoke Start-SourcePlatform -Times 1 -Exactly
            $launch = $global:StartTestLaunch
            $launch.Command.FilePath | Should -Be 'dotnet'
            $launch.Command.Arguments | Should -Be @('VirtoCommerce.Platform.Web.dll')
            $launch.Command.WorkingDirectory | Should -Be $platform
            $launch.LogDir | Should -Be (Join-Path $folder 'logs')
            Should -Invoke Watch-Url-Up -Times 1 -Exactly
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { "$Uri" -like '*/api/platform/modules' }
        }

        It 'stops the platform of an earlier run before it launches a new one' {
            $folder = New-SourceStartFolder (New-PrebuiltPlatform)
            Mock Stop-SourcePlatform { $true }

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            Should -Invoke Stop-SourcePlatform -Times 1 -Exactly
            Should -Invoke Start-SourcePlatform -Times 1 -Exactly
        }

        It 'with SKIP_PLATFORM=true prepares everything, launches and waits for nothing, and prints the launch command' {
            $platform = New-PrebuiltPlatform
            $folder = New-SourceStartFolder $platform @{ SKIP_PLATFORM = 'true' }

            $run = Invoke-StartCapturing $folder

            $run.ExitCode | Should -Be 0
            Join-Path $platform 'VirtoCommerce.Platform.Web.settings.json' | Should -Exist
            Should -Invoke Invoke-DockerCompose -Times 1 -Exactly -ParameterFilter { $args -contains 'up' }
            Should -Invoke Start-SourcePlatform -Times 0
            Should -Invoke Watch-Url-Up -Times 0
            Should -Invoke Get-AuthToken -Times 0
            $run.Output | Should -BeLike '*VirtoCommerce.Platform.Web.dll*'
            $run.Output | Should -BeLike '*ASPNETCORE_ENVIRONMENT=Development*'
            $run.Output | Should -Not -BeLike '*Platform       http*'
        }

        It 'adds the settings file to .git/info/exclude of a checkout, once' {
            $platform = Join-Path $TestDrive "checkout-$([guid]::NewGuid().ToString('N'))"
            $web = Join-Path $platform 'src/VirtoCommerce.Platform.Web'
            $null = New-Item -ItemType Directory -Path $web, (Join-Path $platform '.git') -Force
            Set-Content -LiteralPath (Join-Path $web 'VirtoCommerce.Platform.Web.csproj') -Value '<Project />'
            $folder = New-SourceStartFolder $platform @{ SKIP_PLATFORM = 'true' }

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0
            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            Join-Path $web 'VirtoCommerce.Platform.Web.settings.json' | Should -Exist
            @(Get-Content -LiteralPath (Join-Path $platform '.git/info/exclude') | Where-Object { $_ -eq 'VirtoCommerce.Platform.Web.settings.json' }).Count | Should -Be 1
        }

        It 'links the module sources into the platform folder' -Skip:$IsWindows {
            $platform = New-PrebuiltPlatform
            $module = Join-Path $TestDrive "A-$([guid]::NewGuid().ToString('N')).Web"
            $null = New-Item -ItemType Directory -Path $module
            Set-Content -LiteralPath (Join-Path $module 'module.manifest') -Value '<module><id>VirtoCommerce.A</id></module>'
            $folder = New-SourceStartFolder $platform @{ MODULE_SOURCE_PATHS = $module; SKIP_PLATFORM = 'true' }

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            (Get-Item -LiteralPath (Join-Path $platform 'modules/VirtoCommerce.A')).LinkTarget | Should -Be $module
        }

        It 'fails before the Docker services start when a real modules folder with content is in the way, and names it' -Skip:$IsWindows {
            $platform = New-PrebuiltPlatform
            $null = New-Item -ItemType Directory -Path (Join-Path $platform 'modules/Installed') -Force
            $modules = Join-Path $TestDrive "modules-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $modules
            $folder = New-SourceStartFolder $platform @{ MODULE_SOURCE_PATHS = $modules }

            $run = Invoke-StartCapturing $folder

            $run.ExitCode | Should -Be 1
            $run.Output | Should -BeLike "*$(Join-Path $platform 'modules')*"
            Should -Invoke Invoke-DockerCompose -Times 0 -ParameterFilter { $args -contains 'up' }
            Should -Invoke Start-SourcePlatform -Times 0
        }

        It 'writes nothing and launches nothing when the preflight fails' {
            $platform = New-PrebuiltPlatform
            $folder = New-SourceStartFolder $platform
            Mock Invoke-Preflight { 'A port is already in use.' }

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 1

            Join-Path $platform 'VirtoCommerce.Platform.Web.settings.json' | Should -Not -Exist
            Should -Invoke Start-SourcePlatform -Times 0
        }

        It 'brings Elasticsearch setup up and passes its CA fingerprint on in HTTPS mode' {
            $platform = New-PrebuiltPlatform
            $folder = New-SourceStartFolder $platform @{ SKIP_PLATFORM = 'true' }
            $document = Read-EnvFile (Join-Path $folder '.env')
            Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value 'docker-compose.yml;docker-compose/https.yml;docker-compose/postgres.yml;docker-compose/elasticsearch.yml'
            Write-EnvFile -Document $document -Path (Join-Path $folder '.env')
            Mock Sync-DevCertificate { }
            Mock Test-DevCertificateTrusted { $true }
            Mock Get-ElasticsearchCaFingerprint { 'ab' * 32 }

            Invoke-Start -Folder $folder -SkipSampleData $true | Should -Be 0

            $settings = Get-Content -LiteralPath (Join-Path $platform 'VirtoCommerce.Platform.Web.settings.json') -Raw | ConvertFrom-Json
            $settings.Search.ElasticSearch8.CertificateFingerprint | Should -Be ('ab' * 32)
            $settings.Kestrel.Endpoints.Main.Url | Should -BeLike 'https://*'
        }
    }

    Context 'stop.ps1' {
        It 'stops the source platform even when docker compose down fails' {
            $folder = New-StartFolder
            Mock Invoke-DockerCompose { $global:LASTEXITCODE = 1 }
            Mock Stop-SourcePlatform { $true }

            $global:LASTEXITCODE = 0
            $null = & (Join-Path $folder 'stop.ps1') -solutionFolder $folder *>&1

            $LASTEXITCODE | Should -Be 1
            Should -Invoke Stop-SourcePlatform -Times 1 -Exactly -ParameterFilter {
                ($LogDir -replace '\\', '/') -eq ((Join-Path $folder 'logs') -replace '\\', '/')
            }
        }

        It 'brings the Docker stack down after it stopped the platform' {
            $folder = New-StartFolder
            Mock Invoke-DockerCompose { $global:LASTEXITCODE = 0 }
            Mock Stop-SourcePlatform { $true }

            $global:LASTEXITCODE = 0
            $null = & (Join-Path $folder 'stop.ps1') -solutionFolder $folder *>&1

            $LASTEXITCODE | Should -Be 0
            Should -Invoke Invoke-DockerCompose -Times 1 -Exactly -ParameterFilter { $args -contains 'down' }
        }
    }
}
