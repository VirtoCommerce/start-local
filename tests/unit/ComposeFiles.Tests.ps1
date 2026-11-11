BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    # Short helper: 'yml' -> 'docker-compose.yml', 'platform.https.yml' -> 'docker-compose/platform.https.yml'
    function script:Compose {
        param([string[]]$Suffix)
        [string[]]@($Suffix | ForEach-Object { Get-ComposeFileName $_ })
    }
}

Describe 'ComposeFiles' -Tag 'Unit' {
    It 'default postgres list is canonical' {
        $expected = Compose 'yml', 'https.yml', 'postgres.yml',
        'platform.yml', 'platform.https.yml',
        'elasticsearch.yml', 'elasticsearch.https.yml',
        'kibana.yml', 'kibana.https.yml',
        'redis.yml',
        'frontend.yml', 'frontend.https.yml',
        'platform-postgres.yml',
        'platform-elasticsearch.yml', 'platform-elasticsearch.https.yml',
        'platform-redis.yml',
        'platform-frontend.yml',
        'kibana-elasticsearch.yml', 'kibana-elasticsearch.https.yml'
        $actual = Get-DefaultComposeFiles -Provider postgres
        $actual | Should -Be $expected
    }

    It 'default list without HTTPS has no overlay' {
        $list = Get-DefaultComposeFiles -Provider mysql -Https $false
        $list | Should -Not -Contain 'docker-compose/https.yml'
        $list | Where-Object { $_ -like '*.https.yml' } | Should -BeNullOrEmpty
        $list | Should -Contain 'docker-compose/platform-mysql.yml'
    }

    It 'normalization is idempotent (<Name>)' -TestCases @(
        @{ Name = 'default postgres'; Provider = 'postgres'; Https = $true; Suffix = $null; Modules = $false }
        @{ Name = 'default sqlserver, HTTP'; Provider = 'sqlserver'; Https = $false; Suffix = $null; Modules = $false }
        @{ Name = 'shuffled input'; Provider = $null; Https = $true; Suffix = @('frontend.yml', 'kibana.yml', 'https.yml', 'mysql.yml', 'platform.yml', 'elasticsearch.yml', 'yml'); Modules = $false }
        @{ Name = 'with modules'; Provider = $null; Https = $true; Suffix = @('yml', 'postgres.yml', 'platform.yml'); Modules = $true }
        @{ Name = 'unknown files'; Provider = $null; Https = $true; Suffix = @('x.yml', 'yml', 'my.override.yml', 'redis.yml'); Modules = $false }
        @{ Name = 'host platform'; Provider = $null; Https = $true; Suffix = @('yml', 'https.yml', 'postgres.yml', 'frontend.yml'); Modules = $false }
    ) {
        $files = if ($Provider) { Get-DefaultComposeFiles -Provider $Provider -Https $Https } else { Compose $Suffix }
        $once = Update-ComposeFileList -ComposeFiles $files -HasSourceModules $Modules
        $twice = Update-ComposeFileList -ComposeFiles $once -HasSourceModules $Modules
        $twice | Should -Be $once
    }

    It 'adds the platform-elasticsearch link only when both features are listed' {
        $both = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'platform.yml', 'elasticsearch.yml') -HasSourceModules $false
        $both | Should -Contain 'docker-compose/platform-elasticsearch.yml'

        $platformOnly = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'platform.yml') -HasSourceModules $false
        $platformOnly | Should -Not -Contain 'docker-compose/platform-elasticsearch.yml'

        $elasticsearchOnly = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'elasticsearch.yml', 'platform-elasticsearch.yml') -HasSourceModules $false
        $elasticsearchOnly | Should -Not -Contain 'docker-compose/platform-elasticsearch.yml'
    }

    It 'adds platform-modules only for a Docker platform with source modules' {
        $files = Compose 'yml', 'postgres.yml', 'platform.yml'
        (Update-ComposeFileList -ComposeFiles $files -HasSourceModules $true) | Should -Contain 'docker-compose/platform-modules.yml'
        (Update-ComposeFileList -ComposeFiles $files -HasSourceModules $false) | Should -Not -Contain 'docker-compose/platform-modules.yml'
        $hostPlatform = Compose 'yml', 'postgres.yml'
        (Update-ComposeFileList -ComposeFiles $hostPlatform -HasSourceModules $true) | Should -Not -Contain 'docker-compose/platform-modules.yml'
    }

    It 'lists every overlay iff https.yml is listed' {
        $https = Get-DefaultComposeFiles -Provider postgres
        $plain = Set-ComposeHttps -ComposeFiles $https -Enabled $false
        $plain | Should -Not -Contain 'docker-compose/https.yml'
        @($plain | Where-Object { $_ -like '*.https.yml' }) | Should -HaveCount 0
        $plain | Should -Contain 'docker-compose/platform.yml'

        (Set-ComposeHttps -ComposeFiles $plain -Enabled $true) | Should -Be $https
    }

    It 'does not list an overlay whose base file is not listed' {
        $files = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'https.yml', 'postgres.yml', 'platform.yml') -HasSourceModules $false
        $files | Should -Not -Contain 'docker-compose/elasticsearch.https.yml'
        $files | Should -Not -Contain 'docker-compose/frontend.https.yml'
        $files | Should -Contain 'docker-compose/platform.https.yml'
    }

    It 'skipping and re-adding elasticsearch keeps the HTTPS mode' {
        $start = Get-DefaultComposeFiles -Provider postgres
        $without = Set-ComposeFeature -ComposeFiles $start -Feature elasticsearch -Enabled $false -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -HaveCount 1
        $without | Should -Not -Contain 'docker-compose/elasticsearch.https.yml'
        $without | Should -Not -Contain 'docker-compose/platform-elasticsearch.https.yml'
        $without | Should -Not -Contain 'docker-compose/kibana.yml'

        $back = Set-ComposeFeature -ComposeFiles $without -Feature elasticsearch -Enabled $true
        $back | Should -Contain 'docker-compose/https.yml'
        $back | Should -Contain 'docker-compose/elasticsearch.https.yml'
        $back | Should -Contain 'docker-compose/platform-elasticsearch.https.yml'
    }

    It 'keeps unknown files after built-in files in their order' {
        $input = [string[]]@('my.override.yml', 'docker-compose/redis.yml', 'x.yml', 'docker-compose.yml', 'docker-compose/postgres.yml')
        $result = Update-ComposeFileList -ComposeFiles $input -HasSourceModules $false
        $result | Should -Be ([string[]]@('docker-compose.yml', 'docker-compose/postgres.yml', 'docker-compose/redis.yml', 'my.override.yml', 'x.yml'))
    }

    It 'reports unknown files in Get-ComposeFeatures' {
        $features = Get-ComposeFeatures -ComposeFiles ([string[]]@('docker-compose.yml', 'my.override.yml'))
        $features.Unknown | Should -Be @('my.override.yml')
    }

    Context 'Resolve-DbProvider' {
        It 'returns the provider' {
            Resolve-DbProvider -ComposeFiles (Compose 'yml', 'mysql.yml') | Should -BeExactly 'mysql'
        }

        It 'returns $null with no provider' {
            Resolve-DbProvider -ComposeFiles (Compose 'yml', 'redis.yml') | Should -BeNullOrEmpty
        }

        It 'throws InvalidOperationException when two are listed' {
            { Resolve-DbProvider -ComposeFiles (Compose 'yml', 'mysql.yml', 'postgres.yml') } |
                Should -Throw -ExceptionType ([System.InvalidOperationException])
        }
    }

    It 'Get-ComposeFeatures reads every feature' {
        $features = Get-ComposeFeatures -ComposeFiles (Get-DefaultComposeFiles -Provider sqlserver)
        $features.Provider | Should -BeExactly 'sqlserver'
        $features.Platform | Should -BeTrue
        $features.Elasticsearch | Should -BeTrue
        $features.Kibana | Should -BeTrue
        $features.Redis | Should -BeTrue
        $features.Frontend | Should -BeTrue
        $features.Https | Should -BeTrue
        $features.EsLimited | Should -BeFalse
        @($features.Unknown) | Should -HaveCount 0
    }

    It 'drops kibana with a warning without elasticsearch' {
        $result = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'kibana.yml') -HasSourceModules $false -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -Not -Contain 'docker-compose/kibana.yml'
        $result | Should -Not -Contain 'docker-compose/kibana-elasticsearch.yml'
        $warnings | Should -HaveCount 1
        "$($warnings[0])" | Should -BeLike '*kibana*elasticsearch*'
    }

    It 'drops es-limited with a warning without elasticsearch' {
        $result = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'es-limited.yml') -HasSourceModules $false -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -Not -Contain 'docker-compose/es-limited.yml'
        $warnings | Should -HaveCount 1
        "$($warnings[0])" | Should -BeLike '*es-limited*elasticsearch*'
    }

    It 'keeps es-limited after elasticsearch when elasticsearch is listed' {
        $result = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'es-limited.yml', 'postgres.yml', 'elasticsearch.yml') -HasSourceModules $false
        $result | Should -Be (Compose 'yml', 'postgres.yml', 'elasticsearch.yml', 'es-limited.yml')
    }

    It 'adds frontend-hostplatform when the frontend is listed without the platform' {
        $result = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'frontend.yml') -HasSourceModules $false
        $result | Should -Contain 'docker-compose/frontend-hostplatform.yml'
        $result | Should -Not -Contain 'docker-compose/platform-frontend.yml'
        $result[-1] | Should -BeExactly 'docker-compose/frontend-hostplatform.yml'

        $withPlatform = Update-ComposeFileList -ComposeFiles (Compose 'yml', 'postgres.yml', 'platform.yml', 'frontend.yml', 'frontend-hostplatform.yml') -HasSourceModules $false
        $withPlatform | Should -Not -Contain 'docker-compose/frontend-hostplatform.yml'
        $withPlatform | Should -Contain 'docker-compose/platform-frontend.yml'
    }

    It 'Set-ComposeProvider swaps the provider and its link' {
        $result = Set-ComposeProvider -ComposeFiles (Get-DefaultComposeFiles -Provider postgres) -Provider sqlserver
        $result | Should -Be (Get-DefaultComposeFiles -Provider sqlserver)
        $result | Should -Not -Contain 'docker-compose/platform-postgres.yml'
    }

    It 'Set-ComposeFeature preserves source modules and rejects unknown features' {
        $files = Update-ComposeFileList -ComposeFiles (Get-DefaultComposeFiles -Provider postgres) -HasSourceModules $true
        $files | Should -Contain 'docker-compose/platform-modules.yml'
        (Set-ComposeFeature -ComposeFiles $files -Feature redis -Enabled $false) | Should -Contain 'docker-compose/platform-modules.yml'
        { Set-ComposeFeature -ComposeFiles $files -Feature nope -Enabled $true } | Should -Throw
    }

    Context 'file list value' {
        It 'splits and joins with the separator' {
            $list = Get-ComposeFileList -Value ' docker-compose.yml ;docker-compose/postgres.yml;;'
            $list | Should -Be @('docker-compose.yml', 'docker-compose/postgres.yml')
            ConvertTo-ComposeFileValue -ComposeFiles $list | Should -BeExactly 'docker-compose.yml;docker-compose/postgres.yml'
            ConvertTo-ComposeFileValue -ComposeFiles $list -Separator ':' | Should -BeExactly 'docker-compose.yml:docker-compose/postgres.yml'
            (Get-ComposeFileList -Value 'a.yml:b.yml' -Separator ':') | Should -Be @('a.yml', 'b.yml')
        }

        It 'reads a hand-written backslash as the catalog''s forward slash' {
            $list = Get-ComposeFileList -Value 'docker-compose.yml;docker-compose\postgres.yml'
            $list | Should -Be @('docker-compose.yml', 'docker-compose/postgres.yml')
            (Get-ComposeFeatures -ComposeFiles $list).Provider | Should -Be 'postgres'
        }

        It 'returns an empty array for an empty value' {
            $list = Get-ComposeFileList -Value ''
            , $list | Should -BeOfType ([string[]])
            $list.Count | Should -Be 0
        }

        It 'returns a single file as an array' {
            $list = Get-ComposeFileList -Value 'docker-compose.yml'
            , $list | Should -BeOfType ([string[]])
            $list.Count | Should -Be 1
        }

        It 'chains an empty COMPOSE_FILE straight into the interface functions' {
            $empty = Get-ComposeFileList -Value ''
            (Update-ComposeFileList -ComposeFiles $empty -HasSourceModules $false) | Should -Be @('docker-compose.yml')
            Resolve-DbProvider -ComposeFiles $empty | Should -BeNullOrEmpty
            (Get-ComposeFeatures -ComposeFiles $empty).Platform | Should -BeFalse
            ConvertTo-ComposeFileValue -ComposeFiles $empty | Should -BeExactly ''
            (Set-ComposeProvider -ComposeFiles $empty -Provider mysql) | Should -Contain 'docker-compose/mysql.yml'
            (Set-ComposeHttps -ComposeFiles $empty -Enabled $true) | Should -Contain 'docker-compose/https.yml'
        }
    }

    It 'Get-ComposeProjectName matches the Compose rule (<Folder>)' -TestCases @(
        @{ Folder = 'VirtoLocal'; Expected = 'virtolocal' }
        @{ Folder = 'My Stack.v2'; Expected = 'mystackv2' }
        @{ Folder = '/home/user/_-Edge Case_'; Expected = 'edgecase_' }
        @{ Folder = '/home/user/VirtoLocal/'; Expected = 'virtolocal' }
    ) {
        Get-ComposeProjectName -FolderPath $Folder | Should -BeExactly $Expected
    }

    It 'Get-ComposeProjectName throws when nothing is left of the name' {
        { Get-ComposeProjectName -FolderPath '/home/user/.._a' } | Should -Not -Throw
        { Get-ComposeProjectName -FolderPath '/home/user/..' } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'Get-VolumePrefix and Get-SolutionProjectName use VOLUME_PREFIX, then COMPOSE_PROJECT_NAME, then the folder name' -ForEach @(
        @{ Lines = @('VOLUME_PREFIX=virto', 'COMPOSE_PROJECT_NAME=other'); Prefix = 'virto'; Project = 'other' }
        @{ Lines = @('VOLUME_PREFIX=', 'COMPOSE_PROJECT_NAME=other'); Prefix = 'other'; Project = 'other' }
        @{ Lines = @('VOLUME_PREFIX='); Prefix = 'my-stack'; Project = 'my-stack' }
        @{ Lines = $null; Prefix = 'my-stack'; Project = 'my-stack' }
    ) {
        $document = $null
        if ($Lines) {
            $path = Join-Path 'TestDrive:' "env-$([guid]::NewGuid().ToString('N'))"
            Set-Content -LiteralPath $path -Value $Lines
            $document = Read-EnvFile -Path $path
        }
        $folder = Join-Path 'TestDrive:' 'My-Stack'

        Get-VolumePrefix -Document $document -SolutionFolder $folder | Should -BeExactly $Prefix
        Get-SolutionProjectName -Document $document -SolutionFolder $folder | Should -BeExactly $Project
    }

    It 'Get-SolutionVolumeNames lists the eight volumes' {
        $volumes = Get-SolutionVolumeNames -Prefix virto
        $volumes | Should -Be @(
            'virto_postgres_data', 'virto_mysql_data', 'virto_mssql_data', 'virto_cms-content-data',
            'virto_modules-data', 'virto_esdata01', 'virto_redisdata', 'virto_certs')
    }

    It 'Get-SolutionImageNames lists the two images' {
        $images = Get-SolutionImageNames -ProjectName virtolocal
        $images | Should -Be @('vc-platform:virtolocal-latest', 'vc-frontend:virtolocal-latest')
    }
}
