BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    function New-PreflightFiles {
        # The normalized file list of a stack: base, postgres, platform and the named extras.
        param([string[]]$Extra = @())

        [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml', 'docker-compose.platform.yml') + $Extra
    }

    function New-PreflightEnv {
        param([hashtable]$Override = @{})

        $values = [ordered]@{
            COMPOSE_FILE     = 'docker-compose.yml;docker-compose.postgres.yml;docker-compose.platform.yml'
            RELEASE_CHANNEL  = 'stable'
            PGSQL_PORT       = '5432'
            MYSQL_PORT       = '3306'
            MSSQL_PORT       = '1433'
            ES_PORT          = '9200'
            KIBANA_PORT      = '5601'
            REDIS_PORT       = '6379'
            PLATFORM_PORT    = '8090'
            FRONTEND_PORT    = '443'
        }
        foreach ($key in $Override.Keys) {
            $values[$key] = $Override[$key]
        }
        $values
    }
}

Describe 'Preflight' -Tag 'Unit' {
    Context 'Get-RequiredPorts' {
        It 'follows COMPOSE_FILE: postgres, platform and redis need only their own ports' {
            $files = New-PreflightFiles -Extra 'docker-compose.redis.yml'

            $ports = Get-RequiredPorts -EnvValues (New-PreflightEnv) -ComposeFiles $files

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT', 'PLATFORM_PORT', 'REDIS_PORT')
            ($ports | ForEach-Object { $_.Port }) | Should -Be @(5432, 8090, 6379)
        }

        It 'maps each provider to its own port key' -TestCases @(
            @{ Provider = 'mysql'; Key = 'MYSQL_PORT'; Port = 3306 }
            @{ Provider = 'sqlserver'; Key = 'MSSQL_PORT'; Port = 1433 }
        ) {
            $files = [string[]]@('docker-compose.yml', "docker-compose.$Provider.yml")

            $ports = Get-RequiredPorts -EnvValues (New-PreflightEnv) -ComposeFiles $files

            @($ports).Count | Should -Be 1
            $ports[0].Key | Should -Be $Key
            $ports[0].Port | Should -Be $Port
        }

        It 'maps elasticsearch, kibana and the storefront' {
            $files = New-PreflightFiles -Extra 'docker-compose.elasticsearch.yml', 'docker-compose.kibana.yml', 'docker-compose.frontend.yml'

            $ports = Get-RequiredPorts -EnvValues (New-PreflightEnv) -ComposeFiles $files

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT', 'PLATFORM_PORT', 'ES_PORT', 'KIBANA_PORT', 'FRONTEND_PORT')
        }

        It 'a source platform still requires PLATFORM_PORT' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml')
            $values = New-PreflightEnv @{ PLATFORM_SOURCE_PATH = '/src/vc-platform' }

            $ports = Get-RequiredPorts -EnvValues $values -ComposeFiles $files

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT', 'PLATFORM_PORT')
        }

        It 'a skipped source platform needs no PLATFORM_PORT' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml')
            $values = New-PreflightEnv @{ PLATFORM_SOURCE_PATH = '/src/vc-platform'; SKIP_PLATFORM = 'true' }

            $ports = Get-RequiredPorts -EnvValues $values -ComposeFiles $files

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT')
        }

        It 'own published ports are excluded' {
            $ports = Get-RequiredPorts -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -ExcludePorts 8090

            ($ports | ForEach-Object { $_.Key }) | Should -Be @('PGSQL_PORT')
        }

        It 'uses the standard port when .env leaves the key out' {
            $values = New-PreflightEnv
            $values.Remove('PGSQL_PORT')

            $ports = Get-RequiredPorts -EnvValues $values -ComposeFiles (New-PreflightFiles)

            $ports[0].Port | Should -Be 5432
        }

        It 'names the key when its value is not a port number' {
            { Get-RequiredPorts -EnvValues (New-PreflightEnv @{ PLATFORM_PORT = 'abc' }) -ComposeFiles (New-PreflightFiles) } |
                Should -Throw -ExceptionType ([System.FormatException]) -ExpectedMessage '*PLATFORM_PORT*'
        }
    }

    Context 'Test-PortInUse' {
        It 'sees a listener on the port, and a free port as free' {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            try {
                $busyPort = $listener.LocalEndpoint.Port
                Test-PortInUse -Port $busyPort | Should -BeTrue
            }
            finally {
                $listener.Stop()
            }
            Test-PortInUse -Port $busyPort | Should -BeFalse
        }
    }

    Context 'Get-ServiceUrls' {
        It 'gives HTTP URLs without the https overlay' {
            $urls = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles)

            ($urls | Where-Object { $_.Name -eq 'Platform' }).Url | Should -Be 'http://localhost:8090'
        }

        It 'gives HTTPS URLs with the https mode file, and the storefront on its port' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose.https.yml', 'docker-compose.postgres.yml', 'docker-compose.platform.yml', 'docker-compose.frontend.yml')

            $urls = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles $files

            ($urls | Where-Object { $_.Name -eq 'Platform' }).Url | Should -Be 'https://localhost:8090'
            ($urls | Where-Object { $_.Name -eq 'Storefront' }).Url | Should -Be 'https://localhost:443'
        }

        It 'lists Kibana only when its file is listed' {
            $without = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles -Extra 'docker-compose.elasticsearch.yml')
            $with = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles -Extra 'docker-compose.elasticsearch.yml', 'docker-compose.kibana.yml')

            $without.Name | Should -Not -Contain 'Kibana'
            ($with | Where-Object { $_.Name -eq 'Kibana' }).Url | Should -Be 'http://localhost:5601'
        }

        It 'lists the platform of a source run, and no platform when there is none' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml')

            $source = Get-ServiceUrls -EnvValues (New-PreflightEnv @{ PLATFORM_SOURCE_PATH = '/src/vc-platform' }) -ComposeFiles $files
            $none = Get-ServiceUrls -EnvValues (New-PreflightEnv) -ComposeFiles $files

            ($source | Where-Object { $_.Name -eq 'Platform' }).Url | Should -Be 'http://localhost:8090'
            $none.Name | Should -Not -Contain 'Platform'
        }
    }

    Context 'ConvertTo-PublishedPorts' {
        It 'reads one JSON object per line (Compose 2.21 and later)' {
            $lines = @(
                '{"Name":"a-vc-db-1","Publishers":[{"URL":"127.0.0.1","TargetPort":5432,"PublishedPort":5432,"Protocol":"tcp"}]}'
                '{"Name":"a-vc-platform-web-1","Publishers":[{"URL":"127.0.0.1","TargetPort":8080,"PublishedPort":8090,"Protocol":"tcp"}]}'
            )

            $ports = ConvertTo-PublishedPorts -Json $lines

            $ports | Should -Be @(5432, 8090)
        }

        It 'reads one JSON array (older Compose)' {
            $text = '[{"Name":"a-vc-db-1","Publishers":[{"TargetPort":5432,"PublishedPort":5432}]},{"Name":"a-es-1","Publishers":[{"TargetPort":9200,"PublishedPort":9200}]}]'

            $ports = ConvertTo-PublishedPorts -Json $text

            $ports | Should -Be @(5432, 9200)
        }

        It 'ignores unpublished ports and containers without publishers' {
            $lines = @(
                '{"Name":"a-es-setup-1","Publishers":null}'
                '{"Name":"a-redis-1","Publishers":[{"TargetPort":6379,"PublishedPort":0}]}'
                ''
            )

            $ports = ConvertTo-PublishedPorts -Json $lines

            $ports.Count | Should -Be 0
        }

        It 'returns each port once' {
            $lines = @('{"Publishers":[{"PublishedPort":8090},{"PublishedPort":8090}]}')

            $ports = ConvertTo-PublishedPorts -Json $lines

            $ports | Should -Be @(8090)
        }
    }

    Context 'Invoke-Preflight' {
        BeforeEach {
            Mock Test-DockerRunning { $true }
            Mock Get-ComposeVersion { '2.40.3' }
            Mock Get-ProjectPublishedPorts { [int[]]@() }
            Mock Test-PortInUse { $false }
        }

        It 'reports nothing when everything is in order' {
            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            @($errors).Count | Should -Be 0
        }

        It 'reports an old Compose and names the minimum' {
            Mock Get-ComposeVersion { '2.17.0' }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match '2\.18\.0'
        }

        It 'reports a missing Compose plugin' {
            Mock Get-ComposeVersion { throw [System.InvalidOperationException]::new('no compose') }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match 'Compose v2'
        }

        It 'reports Docker not running and says how to fix it' {
            Mock Test-DockerRunning { $false }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match 'Docker is not running'
            ($errors -join "`n") | Should -Match 'Start Docker'
        }

        It 'reports a busy port with its .env key' {
            Mock Test-PortInUse { $Port -eq 8090 }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match '8090'
            $errors[0] | Should -Match 'PLATFORM_PORT'
        }

        It 'does not flag the ports the stack publishes itself (a re-run on a running stack)' {
            Mock Get-ProjectPublishedPorts { [int[]]@(5432, 8090) }
            Mock Test-PortInUse { $Port -in 5432, 8090 }

            $errors = Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $false

            @($errors).Count | Should -Be 0
        }

        It 'checks only the ports of the listed services' {
            Invoke-Preflight -EnvValues (New-PreflightEnv) -ComposeFiles (New-PreflightFiles) -NonInteractive $true | Out-Null

            Should -Invoke Test-PortInUse -Times 1 -ParameterFilter { $Port -eq 5432 }
            Should -Invoke Test-PortInUse -Times 1 -ParameterFilter { $Port -eq 8090 }
            Should -Invoke Test-PortInUse -Times 0 -ParameterFilter { $Port -eq 6379 }
        }

        It 'names the required .env keys that are empty in a non-interactive run' {
            $values = New-PreflightEnv @{ RELEASE_CHANNEL = '' }

            $errors = Invoke-Preflight -EnvValues $values -ComposeFiles (New-PreflightFiles) -NonInteractive $true

            ($errors -join "`n") | Should -Match 'RELEASE_CHANNEL'
        }

        It 'leaves the required keys to the prompts in an interactive run' {
            $values = New-PreflightEnv @{ RELEASE_CHANNEL = '' }

            $errors = Invoke-Preflight -EnvValues $values -ComposeFiles (New-PreflightFiles) -NonInteractive $false

            @($errors).Count | Should -Be 0
        }
    }
}

Describe 'Source platform preflight' -Tag 'Unit' {
    BeforeAll {
        function script:New-SourcePlatformFolder {
            param([switch]$Built, [ValidateSet('checkout', 'prebuilt')][string]$Kind = 'checkout')

            $folder = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) 'platform'
            if ($Kind -eq 'checkout') {
                $web = Join-Path $folder 'src/VirtoCommerce.Platform.Web'
                $null = New-Item -ItemType Directory -Path $web -Force
                Set-Content -LiteralPath (Join-Path $web 'VirtoCommerce.Platform.Web.csproj') -Value '<Project />'
                if ($Built) {
                    $null = New-Item -ItemType Directory -Path (Join-Path $web 'bin/Debug') -Force
                    Set-Content -LiteralPath (Join-Path $web 'bin/Debug/VirtoCommerce.Platform.Web.dll') -Value 'x'
                }
            }
            else {
                $null = New-Item -ItemType Directory -Path $folder -Force
                if ($Built) {
                    Set-Content -LiteralPath (Join-Path $folder 'VirtoCommerce.Platform.Web.dll') -Value 'x'
                }
            }
            $folder
        }

        function script:New-SourceEnv {
            param([string]$PlatformPath, [hashtable]$Override = @{})

            $values = [ordered]@{
                COMPOSE_FILE         = 'docker-compose.yml;docker-compose.postgres.yml'
                RELEASE_CHANNEL      = 'stable'
                PLATFORM_SOURCE_PATH = $PlatformPath
                PLATFORM_PORT        = '8090'
            }
            foreach ($key in $Override.Keys) {
                $values[$key] = $Override[$key]
            }
            $values
        }

        $script:sourceStack = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml')
    }

    BeforeEach {
        Mock Test-DockerRunning { $true }
        Mock Get-ComposeVersion { '2.40.3' }
        Mock Get-ProjectPublishedPorts { [int[]]@() }
        Mock Test-PortInUse { $false }
        Mock Test-FileSharing { $true }
        Mock Get-RunningSourcePlatform { $null }
        Mock Test-SymlinkRights { $true }
    }

    It 'reports a missing build output and names the folder' {
        $path = New-SourcePlatformFolder

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 1
        $errors[0] | Should -BeLike "*$(Join-Path $path 'src/VirtoCommerce.Platform.Web')*"
        $errors[0] | Should -Match 'build'
    }

    It 'reports a folder that is neither a checkout nor a prebuilt platform, and names it' {
        $path = New-SourcePlatformFolder -Kind prebuilt

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 1
        $errors[0] | Should -BeLike "*$path*"
        $errors[0] | Should -Match 'PLATFORM_SOURCE_PATH'
    }

    It 'reports nothing for a built checkout and a prebuilt folder' {
        foreach ($kind in 'checkout', 'prebuilt') {
            $path = New-SourcePlatformFolder -Kind $kind -Built

            $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

            @($errors).Count | Should -Be 0
        }
    }

    It 'asks for no build output when SKIP_PLATFORM=true' {
        $path = New-SourcePlatformFolder

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path @{ SKIP_PLATFORM = 'true' }) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 0
    }

    It 'checks nothing about a source platform for a Docker platform' {
        $files = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml', 'docker-compose.platform.yml')

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv '') -ComposeFiles $files -NonInteractive $true

        @($errors).Count | Should -Be 0
    }

    It 'does not flag the port of the source platform that this folder started itself' {
        $path = New-SourcePlatformFolder -Built
        Mock Get-RunningSourcePlatform { [System.Diagnostics.Process]::GetCurrentProcess() }
        Mock Test-PortInUse { $Port -eq 8090 }

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 0
    }

    It 'still flags the port when no source platform of this folder runs' {
        $path = New-SourcePlatformFolder -Built
        Mock Test-PortInUse { $Port -eq 8090 }

        $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

        @($errors).Count | Should -Be 1
        $errors[0] | Should -Match 'PLATFORM_PORT'
    }

    Context 'symlink rights for the module links' {
        It 'asks for Developer Mode or an elevated shell when links are planned and cannot be made' {
            $path = New-SourcePlatformFolder -Built
            $web = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'
            Mock Test-SymlinkRights { $false }

            $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path @{ MODULE_SOURCE_PATHS = $web }) -ComposeFiles $script:sourceStack -NonInteractive $true

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match 'Developer Mode or run an elevated shell'
        }

        It 'does not ask without module sources, even where links cannot be made' {
            $path = New-SourcePlatformFolder -Built
            Mock Test-SymlinkRights { $false }

            $errors = Invoke-Preflight -EnvValues (New-SourceEnv $path) -ComposeFiles $script:sourceStack -NonInteractive $true

            @($errors).Count | Should -Be 0
            Should -Invoke Test-SymlinkRights -Times 0
        }

        It 'does not ask when the platform runs in Docker (the sources are bind-mounted)' {
            $web = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'
            $files = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml', 'docker-compose.platform.yml')
            Mock Test-SymlinkRights { $false }

            $errors = Invoke-Preflight -EnvValues (New-SourceEnv '' @{ MODULE_SOURCE_PATHS = $web }) -ComposeFiles $files -NonInteractive $true

            @($errors).Count | Should -Be 0
        }
    }
}
