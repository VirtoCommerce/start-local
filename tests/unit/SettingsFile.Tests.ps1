BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    # .env.example plus the four secrets, as the table Get-EnvTable gives.
    function script:New-EnvValues {
        param([hashtable]$Override = @{})
        $document = Read-EnvFile -Path (Join-Path $PSScriptRoot '../../.env.example')
        $secrets = @{ DB_PASSWORD = 'pg1'; REDIS_PASSWORD = 'r1'; ELASTIC_PASSWORD = 'e1'; KIBANA_PASSWORD = 'k1' }
        foreach ($pair in $secrets.GetEnumerator() + $Override.GetEnumerator()) {
            Set-EnvValue -Document $document -Key $pair.Key -Value $pair.Value
        }
        Get-EnvTable -Document $document
    }

    function script:Get-Settings {
        param(
            [string]$Topology = 'Container',
            [string]$Provider = 'postgres',
            [bool]$Https = $false,
            [hashtable]$Override = @{},
            [string[]]$Without = @(),
            [string]$CaFingerprint
        )
        $defaults = Get-DefaultComposeFiles -Provider $Provider -Https $Https
        $files = [string[]]@($defaults | Where-Object { $Without -cnotcontains $_ })
        $arguments = @{ EnvValues = (New-EnvValues -Override $Override); ComposeFiles = $files; Topology = $Topology }
        if ($CaFingerprint) {
            $arguments.CaFingerprint = $CaFingerprint
        }
        Get-PlatformSettings @arguments
    }
}

Describe 'SettingsFile' -Tag 'Unit' {
    Context 'Get-PlatformSettings, Container topology' {
        It 'equals the postgres HTTP table, in order' {
            $settings = Get-Settings
            $expected = [ordered]@{
                'DatabaseProvider'                        = 'PostgreSql'
                'ConnectionStrings:VirtoCommerce'         = 'User ID=postgres;Password=pg1;Host=vc-db;Port=5432;Database=VirtoCommerce3'
                'VirtoCommerce:AllowInsecureHttp'         = 'true'
                'VirtoCommerce:Hangfire:JobStorageType'   = 'Memory'
                'Assets:FileSystem:PublicUrl'             = 'http://localhost:8090/assets/'
                'Content:FileSystem:PublicUrl'            = 'http://localhost:8090/cms-content/'
                'Search:Provider'                         = 'ElasticSearch8'
                'Search:ElasticSearch8:Server'            = 'http://es:9200'
                'Search:ElasticSearch8:User'              = 'elastic'
                'Search:ElasticSearch8:Key'               = 'e1'
                'ConnectionStrings:RedisConnectionString' = 'redis:6379,password=r1'
            }
            @($settings.Keys) | Should -Be @($expected.Keys)
            @($settings.Values) | Should -Be @($expected.Values)
        }

        It 'maps mysql' {
            $settings = Get-Settings -Provider mysql
            $settings['DatabaseProvider'] | Should -Be 'MySql'
            $settings['ConnectionStrings:VirtoCommerce'] | Should -Be 'Server=vc-db;Port=3306;Database=VirtoCommerce3;User=root;Password=pg1'
        }

        It 'maps sqlserver' {
            $settings = Get-Settings -Provider sqlserver
            $settings['DatabaseProvider'] | Should -Be 'SqlServer'
            $settings['ConnectionStrings:VirtoCommerce'] | Should -Be 'Server=vc-db,1433;Database=VirtoCommerce3;User Id=sa;Password=pg1;TrustServerCertificate=True'
        }

        It 'omits Search keys without elasticsearch and the Redis key without redis' {
            $noSearch = Get-Settings -Without 'docker-compose.elasticsearch.yml'
            @($noSearch.Keys | Where-Object { $_ -like 'Search:*' }) | Should -BeNullOrEmpty
            $noSearch.Contains('ConnectionStrings:RedisConnectionString') | Should -BeTrue

            $noRedis = Get-Settings -Without 'docker-compose.redis.yml'
            $noRedis.Contains('ConnectionStrings:RedisConnectionString') | Should -BeFalse
            $noRedis.Contains('Search:Provider') | Should -BeTrue
        }

        It 'does not need the secrets of features that are not listed' {
            $defaults = Get-DefaultComposeFiles -Provider postgres
            $files = [string[]]@($defaults | Where-Object { $_ -cnotmatch 'elasticsearch|redis|kibana' })
            $values = New-EnvValues -Override @{ REDIS_PASSWORD = ''; ELASTIC_PASSWORD = '' }
            { Get-PlatformSettings -EnvValues $values -ComposeFiles $files -Topology Container } | Should -Not -Throw
        }

        It 'follows PLATFORM_PORT in the public URLs' {
            $settings = Get-Settings -Override @{ PLATFORM_PORT = '8123' }
            $settings['Assets:FileSystem:PublicUrl'] | Should -Be 'http://localhost:8123/assets/'
            $settings['Content:FileSystem:PublicUrl'] | Should -Be 'http://localhost:8123/cms-content/'
        }

        It 'switches to HTTPS' {
            $settings = Get-Settings -Https $true
            $settings['VirtoCommerce:AllowInsecureHttp'] | Should -Be 'false'
            $settings['Assets:FileSystem:PublicUrl'] | Should -Be 'https://localhost:8090/assets/'
            $settings['Content:FileSystem:PublicUrl'] | Should -Be 'https://localhost:8090/cms-content/'
            $settings['Search:ElasticSearch8:Server'] | Should -Be 'https://es:9200'
        }

        It 'renames the Search keys for SEARCH_PROVIDER=ElasticSearch9' {
            $settings = Get-Settings -Override @{ SEARCH_PROVIDER = 'ElasticSearch9' }
            $settings['Search:Provider'] | Should -Be 'ElasticSearch9'
            $settings['Search:ElasticSearch9:Server'] | Should -Be 'http://es:9200'
            $settings['Search:ElasticSearch9:User'] | Should -Be 'elastic'
            $settings['Search:ElasticSearch9:Key'] | Should -Be 'e1'
            @($settings.Keys | Where-Object { $_ -like 'Search:ElasticSearch8:*' }) | Should -BeNullOrEmpty
        }

        It 'never emits the Host-only keys' {
            $settings = Get-Settings -CaFingerprint 'abc123' -Https $true
            foreach ($key in 'Kestrel:Endpoints:Main:Url', 'Search:ElasticSearch8:CertificateFingerprint') {
                $settings.Contains($key) | Should -BeFalse
            }
        }

        It 'fails and names the key when a needed secret is empty' {
            { Get-Settings -Override @{ DB_PASSWORD = '' } } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*DB_PASSWORD*'
        }

        It 'fails when COMPOSE_FILE lists no database provider' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose.platform.yml')
            { Get-PlatformSettings -EnvValues (New-EnvValues) -ComposeFiles $files -Topology Container } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*database provider*'
        }
    }

    Context 'Get-PlatformSettings, Host topology' {
        It 'reaches the services through localhost and the published ports' {
            $settings = Get-Settings -Topology Host
            $settings['ConnectionStrings:VirtoCommerce'] | Should -Be 'User ID=postgres;Password=pg1;Host=localhost;Port=5432;Database=VirtoCommerce3'
            $settings['Search:ElasticSearch8:Server'] | Should -Be 'http://localhost:9200'
            $settings['ConnectionStrings:RedisConnectionString'] | Should -Be 'localhost:6379,password=r1'
            $settings['Kestrel:Endpoints:Main:Url'] | Should -Be 'http://127.0.0.1:8090'
        }

        It 'uses the published port values from .env' {
            $settings = Get-Settings -Topology Host -Override @{ PGSQL_PORT = '15432'; ES_PORT = '19200'; REDIS_PORT = '16379'; PLATFORM_PORT = '18090'; BIND_ADDRESS = '0.0.0.0' }
            $settings['ConnectionStrings:VirtoCommerce'] | Should -BeLike '*Host=localhost;Port=15432;*'
            $settings['Search:ElasticSearch8:Server'] | Should -Be 'http://localhost:19200'
            $settings['ConnectionStrings:RedisConnectionString'] | Should -Be 'localhost:16379,password=r1'
            $settings['Kestrel:Endpoints:Main:Url'] | Should -Be 'http://0.0.0.0:18090'
        }

        It 'falls back to 127.0.0.1 for an empty BIND_ADDRESS' {
            $settings = Get-Settings -Topology Host -Override @{ BIND_ADDRESS = '' }
            $settings['Kestrel:Endpoints:Main:Url'] | Should -Be 'http://127.0.0.1:8090'
        }

        It 'maps mysql and sqlserver to localhost' {
            (Get-Settings -Topology Host -Provider mysql)['ConnectionStrings:VirtoCommerce'] |
                Should -Be 'Server=localhost;Port=3306;Database=VirtoCommerce3;User=root;Password=pg1'
            (Get-Settings -Topology Host -Provider sqlserver)['ConnectionStrings:VirtoCommerce'] |
                Should -Be 'Server=localhost,1433;Database=VirtoCommerce3;User Id=sa;Password=pg1;TrustServerCertificate=True'
        }

        It 'uses https URLs in HTTPS mode' {
            $settings = Get-Settings -Topology Host -Https $true
            $settings['Search:ElasticSearch8:Server'] | Should -Be 'https://localhost:9200'
            $settings['Kestrel:Endpoints:Main:Url'] | Should -Be 'https://127.0.0.1:8090'
            $settings['VirtoCommerce:AllowInsecureHttp'] | Should -Be 'false'
        }

        It 'emits CertificateFingerprint only for Host, and only when one is given' {
            $with = Get-Settings -Topology Host -Https $true -CaFingerprint 'abc123'
            $with['Search:ElasticSearch8:CertificateFingerprint'] | Should -Be 'abc123'
            @($with.Keys).IndexOf('Search:ElasticSearch8:CertificateFingerprint') |
                Should -BeGreaterThan @($with.Keys).IndexOf('Search:ElasticSearch8:Key')

            (Get-Settings -Topology Host -Https $true).Contains('Search:ElasticSearch8:CertificateFingerprint') | Should -BeFalse
            (Get-Settings -Topology Host -Https $true -Without 'docker-compose.elasticsearch.yml' -CaFingerprint 'abc123').Keys |
                Where-Object { $_ -like '*CertificateFingerprint' } | Should -BeNullOrEmpty
        }

        It 'names the fingerprint key after SEARCH_PROVIDER' {
            $settings = Get-Settings -Topology Host -Https $true -CaFingerprint 'abc123' -Override @{ SEARCH_PROVIDER = 'ElasticSearch9' }
            $settings['Search:ElasticSearch9:CertificateFingerprint'] | Should -Be 'abc123'
        }
    }

    Context 'Get-DbSettings' {
        It 'returns the provider name and connection string (<Provider>, <Topology>)' -ForEach @(
            @{ Provider = 'postgres'; Topology = 'Container'; Name = 'PostgreSql'; Connection = 'User ID=postgres;Password=pg1;Host=vc-db;Port=5432;Database=VirtoCommerce3' }
            @{ Provider = 'postgres'; Topology = 'Host'; Name = 'PostgreSql'; Connection = 'User ID=postgres;Password=pg1;Host=localhost;Port=5432;Database=VirtoCommerce3' }
            @{ Provider = 'mysql'; Topology = 'Host'; Name = 'MySql'; Connection = 'Server=localhost;Port=3306;Database=VirtoCommerce3;User=root;Password=pg1' }
            @{ Provider = 'sqlserver'; Topology = 'Container'; Name = 'SqlServer'; Connection = 'Server=vc-db,1433;Database=VirtoCommerce3;User Id=sa;Password=pg1;TrustServerCertificate=True' }
        ) {
            $settings = Get-DbSettings -Provider $Provider -EnvValues (New-EnvValues) -Topology $Topology
            @($settings.Keys) | Should -Be @('DatabaseProvider', 'ConnectionStrings:VirtoCommerce')
            $settings['DatabaseProvider'] | Should -Be $Name
            $settings['ConnectionStrings:VirtoCommerce'] | Should -Be $Connection
        }

        It 'rejects an unknown provider or topology' {
            { Get-DbSettings -Provider 'oracle' -EnvValues (New-EnvValues) -Topology Container } | Should -Throw
            { Get-DbSettings -Provider 'postgres' -EnvValues (New-EnvValues) -Topology Cloud } | Should -Throw
        }
    }

    Context 'ConvertTo-SettingsJson' {
        It 'nests the flat keys by colon' {
            $flat = Get-Settings -Topology Host -Https $true -CaFingerprint 'abc123'
            $json = ConvertTo-SettingsJson -Flat $flat
            $parsed = $json | ConvertFrom-Json
            $parsed.ConnectionStrings.VirtoCommerce | Should -Be $flat['ConnectionStrings:VirtoCommerce']
            $parsed.ConnectionStrings.RedisConnectionString | Should -Be $flat['ConnectionStrings:RedisConnectionString']
            $parsed.VirtoCommerce.Hangfire.JobStorageType | Should -Be 'Memory'
            $parsed.Search.ElasticSearch8.CertificateFingerprint | Should -Be 'abc123'
            $parsed.Kestrel.Endpoints.Main.Url | Should -Be 'https://127.0.0.1:8090'
            $parsed.DatabaseProvider | Should -Be 'PostgreSql'
        }

        It 'round-trips every flat key and value' {
            $flat = Get-Settings -Topology Host
            $parsed = ConvertTo-SettingsJson -Flat $flat | ConvertFrom-Json -AsHashtable
            foreach ($key in $flat.Keys) {
                $node = $parsed
                foreach ($segment in $key.Split(':')) { $node = $node[$segment] }
                $node | Should -Be $flat[$key]
            }
        }

        It 'keeps characters JSON escapes' {
            $json = ConvertTo-SettingsJson -Flat ([ordered]@{ 'ConnectionStrings:VirtoCommerce' = "a'b<c>&`"d\e" })
            ($json | ConvertFrom-Json).ConnectionStrings.VirtoCommerce | Should -Be "a'b<c>&`"d\e"
        }

        It 'fails when a key is both a value and a section' {
            { ConvertTo-SettingsJson -Flat ([ordered]@{ 'A' = '1'; 'A:B' = '2' }) } |
                Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*A*'
        }
    }

    Context 'Get-SettingsFilePath' {
        It 'puts a checkout file under src/VirtoCommerce.Platform.Web' {
            (Get-SettingsFilePath -PlatformPath '/p' -Kind checkout) -replace '\\', '/' |
                Should -Be '/p/src/VirtoCommerce.Platform.Web/VirtoCommerce.Platform.Web.settings.json'
        }

        It 'puts a prebuilt file in the folder itself' {
            (Get-SettingsFilePath -PlatformPath '/p' -Kind prebuilt) -replace '\\', '/' | Should -Be '/p/VirtoCommerce.Platform.Web.settings.json'
        }

        It 'rejects an unknown kind' {
            { Get-SettingsFilePath -PlatformPath '/p' -Kind other } | Should -Throw
        }
    }

    Context 'key ownership lists' {
        It 'lists the container-only keys' {
            Get-ContainerOnlyKeys | Should -Be @('ASPNETCORE_URLS', 'Kestrel:Certificates:Default:Path', 'Kestrel:Certificates:Default:KeyPath', 'SEARCH_PROVIDER')
        }

        It 'lists the host-only keys' {
            Get-HostOnlyKeys | Should -Be @('Kestrel:Endpoints:Main:Url', 'Search:<provider>:CertificateFingerprint')
        }
    }
}

Describe 'Source platform settings file' -Tag 'Unit' {
    Context 'Write-PlatformSettingsFile' {
        It 'writes the flat settings as nested JSON, in UTF-8 without a byte order mark' {
            $path = Join-Path $TestDrive 'settings.json'

            Write-PlatformSettingsFile -Path $path -Flat ([ordered]@{ 'DatabaseProvider' = 'PostgreSql'; 'Kestrel:Endpoints:Main:Url' = 'http://127.0.0.1:8090' })

            $bytes = [System.IO.File]::ReadAllBytes($path)
            $bytes[0] | Should -Not -Be 0xEF
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $json.DatabaseProvider | Should -Be 'PostgreSql'
            $json.Kestrel.Endpoints.Main.Url | Should -Be 'http://127.0.0.1:8090'
        }

        It 'replaces the file of an earlier run' {
            $path = Join-Path $TestDrive 'settings-again.json'
            Write-PlatformSettingsFile -Path $path -Flat ([ordered]@{ 'A' = '1'; 'B' = '2' })

            Write-PlatformSettingsFile -Path $path -Flat ([ordered]@{ 'A' = '3' })

            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $json.A | Should -Be '3'
            $json.PSObject.Properties.Name | Should -Not -Contain 'B'
        }

        It 'writes what Get-PlatformSettings gives for the Host topology' {
            $path = Join-Path $TestDrive 'settings-host.json'
            $files = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml')

            Write-PlatformSettingsFile -Path $path -Flat (Get-PlatformSettings -EnvValues (New-EnvValues) -ComposeFiles $files -Topology Host)

            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $json.ConnectionStrings.VirtoCommerce | Should -BeLike '*Host=localhost*'
            $json.Kestrel.Endpoints.Main.Url | Should -Be 'http://127.0.0.1:8090'
        }
    }

    Context 'Get-ShadowedKeys' {
        It 'names the setting keys that the user secrets also define' {
            $secrets = '{"ConnectionStrings:VirtoCommerce":"x","Unrelated:Key":"y"}'

            $shadowed = Get-ShadowedKeys -SecretsJson $secrets -SettingKeys @('DatabaseProvider', 'ConnectionStrings:VirtoCommerce')

            $shadowed | Should -Be @('ConnectionStrings:VirtoCommerce')
        }

        It 'reads nested secrets and ignores the case of keys, as .NET configuration does' {
            $secrets = '{"connectionstrings":{"virtocommerce":"x"}}'

            $shadowed = Get-ShadowedKeys -SecretsJson $secrets -SettingKeys @('ConnectionStrings:VirtoCommerce')

            $shadowed | Should -Be @('ConnectionStrings:VirtoCommerce')
        }

        It 'gives nothing for no secrets, an empty store, or text that is not JSON' {
            foreach ($secrets in '', '{}', 'not json', '[1,2]') {
                $shadowed = Get-ShadowedKeys -SecretsJson $secrets -SettingKeys @('A')
                @($shadowed).Count | Should -Be 0
            }
        }

        It 'returns a string array even for no match' {
            (Get-ShadowedKeys -SecretsJson '{}' -SettingKeys @('A')) -is [string[]] | Should -BeTrue
        }
    }

    Context 'Get-PlatformUserSecretsPath' {
        It 'points into the per-user secrets store of VirtoCommerce.Platform.Web' {
            ((Get-PlatformUserSecretsPath) -replace '\\', '/') | Should -BeLike '*/VirtoCommerce.Platform.Web/secrets.json'
        }
    }
}
