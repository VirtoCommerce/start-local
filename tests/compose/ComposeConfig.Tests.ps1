BeforeDiscovery {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)

    # 3 providers x platform/storefront (none, platform, platform + storefront, storefront on a host platform)
    # x Elasticsearch on/off x Kibana (with Elasticsearch only) x Redis on/off x es-limited (with Elasticsearch only), HTTP mode.
    $script:stacks = [ordered]@{
        none               = @()
        platform           = @('platform')
        'platform+frontend' = @('platform', 'frontend')
        frontend           = @('frontend')
    }
    $script:cases = foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
        foreach ($stack in $script:stacks.Keys) {
            foreach ($elasticsearch in $false, $true) {
                foreach ($kibana in ($(if ($elasticsearch) { $false, $true } else { $false }))) {
                    foreach ($esLimited in ($(if ($elasticsearch) { $false, $true } else { $false }))) {
                        foreach ($redis in $false, $true) {
                            $requested = [System.Collections.Generic.List[string]]::new()
                            $requested.Add('docker-compose.yml')
                            $requested.Add("docker-compose.$provider.yml")
                            $features = [ordered]@{ elasticsearch = $elasticsearch; kibana = $kibana; redis = $redis; 'es-limited' = $esLimited }
                            foreach ($feature in $script:stacks[$stack]) {
                                $features[$feature] = $true
                            }
                            foreach ($feature in $features.Keys) {
                                if ($features[$feature]) {
                                    $requested.Add("docker-compose.$feature.yml")
                                }
                            }
                            $label = (@($provider) + @($features.Keys | Where-Object { $features[$_] })) -join '+'
                            @{
                                Label         = $label
                                Provider      = $provider
                                Platform      = $script:stacks[$stack] -contains 'platform'
                                Frontend      = $script:stacks[$stack] -contains 'frontend'
                                Elasticsearch = $elasticsearch
                                Kibana        = $kibana
                                Redis         = $redis
                                EsLimited     = $esLimited
                                ComposeFiles  = [string[]](Update-ComposeFileList -ComposeFiles $requested.ToArray() -HasSourceModules $false)
                            }
                        }
                    }
                }
            }
        }
    }
    $script:providerVolume = @{ postgres = 'postgres_data'; mysql = 'mysql_data'; sqlserver = 'mssql_data' }
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    function script:Get-PublishedPorts {
        param($Config)
        foreach ($service in $Config.services.PSObject.Properties.Value) {
            foreach ($port in $service.ports) {
                $port
            }
        }
    }
}

Describe 'Compose config' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    Context '<Label>' -ForEach $script:cases {
        BeforeAll {
            $script:folders = [System.Collections.Generic.List[string]]::new()
            $folder = New-ComposeFixtureFolder -ComposeFiles $ComposeFiles
            $script:folders.Add($folder)
            $script:configError = $null
            $script:config = $null
            try {
                $script:config = Invoke-ComposeConfigJson $folder
            }
            catch {
                $script:configError = $_.Exception.Message
            }

            $script:prefixedFolder = New-ComposeFixtureFolder -ComposeFiles $ComposeFiles -EnvOverrides @{ VOLUME_PREFIX = 'virto' }
            $script:folders.Add($script:prefixedFolder)
        }

        AfterAll {
            foreach ($folder in $script:folders) {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'config succeeds' {
            $script:configError | Should -BeNullOrEmpty
            $script:config | Should -Not -BeNullOrEmpty
        }

        It 'every published port binds 127.0.0.1' {
            $ports = @(Get-PublishedPorts $script:config)
            $ports.Count | Should -BeGreaterThan 0
            foreach ($port in $ports) {
                $port.host_ip | Should -Be '127.0.0.1'
            }
        }

        It 'volume names use VOLUME_PREFIX' {
            $script:config.volumes.($providerVolume[$Provider]).name | Should -Be "fixture_$($providerVolume[$Provider])"
            $prefixed = Invoke-ComposeConfigJson $script:prefixedFolder
            $prefixed.volumes.($providerVolume[$Provider]).name | Should -Be "virto_$($providerVolume[$Provider])"
            foreach ($volume in $prefixed.volumes.PSObject.Properties.Value) {
                $volume.name | Should -BeLike 'virto_*'
            }
            if ($Elasticsearch) {
                $prefixed.volumes.esdata01.name | Should -Be 'virto_esdata01'
            }
        }

        It 'long-running services restart unless-stopped' {
            foreach ($service in $script:config.services.PSObject.Properties) {
                $service.Value.restart | Should -Be 'unless-stopped' -Because "service $($service.Name)"
            }
        }

        It 'es-limited sets single-node and drops memlock' {
            if (-not $Elasticsearch) {
                $script:config.services.PSObject.Properties.Name | Should -Not -Contain 'es'
                return
            }
            $es = $script:config.services.es
            if ($EsLimited) {
                $es.environment.'discovery.type' | Should -Be 'single-node'
                $es.environment.'bootstrap.memory_lock' | Should -Be 'false'
                # Strictly null, not '': an empty value crashes Elasticsearch ("null-valued setting")
                $es.environment.PSObject.Properties.Name | Should -Contain 'cluster.initial_master_nodes'
                ($null -eq $es.environment.'cluster.initial_master_nodes') | Should -BeTrue
                $es.PSObject.Properties.Name | Should -Not -Contain 'ulimits'
            }
            else {
                $es.environment.PSObject.Properties.Name | Should -Not -Contain 'discovery.type'
                $es.environment.'cluster.initial_master_nodes' | Should -Be 'es'
                $es.environment.'bootstrap.memory_lock' | Should -Be 'true'
                $es.ulimits.memlock.soft | Should -Be -1
            }
        }

        It 'vc-db has a healthcheck' {
            $script:config.services.'vc-db'.healthcheck.test | Should -Not -BeNullOrEmpty
        }

        It 'wires only the services that are listed' {
            $names = @($script:config.services.PSObject.Properties.Name)
            ($names -contains 'es') | Should -Be $Elasticsearch
            ($names -contains 'kibana') | Should -Be $Kibana
            ($names -contains 'redis') | Should -Be $Redis
            ($names -contains 'vc-db') | Should -BeTrue
            ($names -contains 'vc-platform-web') | Should -Be $Platform
            ($names -contains 'vc-frontend') | Should -Be $Frontend
        }

        It 'platform depends_on is exactly the implied set, all service_healthy' {
            if (-not $Platform) {
                return
            }
            $implied = @('vc-db') + @(if ($Elasticsearch) { 'es' }) + @(if ($Redis) { 'redis' })
            $dependsOn = $script:config.services.'vc-platform-web'.depends_on
            @($dependsOn.PSObject.Properties.Name | Sort-Object) | Should -Be @($implied | Sort-Object)
            foreach ($dependency in $dependsOn.PSObject.Properties) {
                $dependency.Value.condition | Should -Be 'service_healthy' -Because "dependency $($dependency.Name)"
            }
        }

        It 'image tags are vc-platform:<project>-latest and vc-frontend:<project>-latest' {
            if ($Platform) {
                $script:config.services.'vc-platform-web'.image | Should -Be "vc-platform:$($script:config.name)-latest"
            }
            if ($Frontend) {
                $script:config.services.'vc-frontend'.image | Should -Be "vc-frontend:$($script:config.name)-latest"
            }
        }

        It 'frontend without platform gets host.docker.internal upstream and the host-gateway extra_host' {
            if (-not $Frontend) {
                $script:config.services.PSObject.Properties.Name | Should -Not -Contain 'vc-frontend'
                return
            }
            $frontend = $script:config.services.'vc-frontend'
            if ($Platform) {
                $frontend.environment.PLATFORM_UPSTREAM | Should -Be 'vc-platform-web:8080'
                $frontend.depends_on.'vc-platform-web'.condition | Should -Be 'service_healthy'
                $frontend.PSObject.Properties.Name | Should -Not -Contain 'extra_hosts'
            }
            else {
                $frontend.environment.PLATFORM_UPSTREAM | Should -Be 'host.docker.internal:8090'
                @($frontend.extra_hosts) | Should -Contain 'host.docker.internal=host-gateway'
                $frontend.PSObject.Properties.Name | Should -Not -Contain 'depends_on'
            }
            $frontend.environment.PLATFORM_SCHEME | Should -Be 'http'
            $frontend.environment.NGINX_ENVSUBST_TEMPLATE_DIR | Should -Be '/etc/nginx/templates-http'
        }

        It 'platform-modules is never listed without source modules' {
            $ComposeFiles | Should -Not -Contain 'docker-compose.platform-modules.yml'
        }
    }

    It 'project name matches Get-ComposeProjectName (<FolderName>)' -ForEach @(
        @{ FolderName = 'VirtoLocal' }
        @{ FolderName = 'My Stack.v2' }
    ) {
        $folder = New-ComposeFixtureFolder -ComposeFiles 'docker-compose.yml', 'docker-compose.postgres.yml' -FolderName $FolderName
        try {
            (Invoke-ComposeConfigJson $folder).name | Should -Be (Get-ComposeProjectName $folder)
        }
        finally {
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Compose V12: all links of a platform' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    It 'merges depends_on of vc-db, es and redis, each service_healthy' {
        $files = [string[]](Update-ComposeFileList -HasSourceModules $false -ComposeFiles @(
                'docker-compose.yml', 'docker-compose.postgres.yml', 'docker-compose.platform.yml',
                'docker-compose.elasticsearch.yml', 'docker-compose.redis.yml', 'docker-compose.frontend.yml'))
        $folder = New-ComposeFixtureFolder -ComposeFiles $files
        try {
            $dependsOn = (Invoke-ComposeConfigJson $folder).services.'vc-platform-web'.depends_on
            foreach ($name in 'vc-db', 'es', 'redis') {
                $dependsOn.$name.condition | Should -Be 'service_healthy' -Because "dependency $name"
            }
        }
        finally {
            Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Compose files' -Tag 'Compose' {
    It 'platform-modules is listed only with source modules and a platform' {
        $base = 'docker-compose.yml', 'docker-compose.postgres.yml'
        $withPlatform = [string[]]($base + 'docker-compose.platform.yml')
        $modules = 'docker-compose.platform-modules.yml'
        [string[]](Update-ComposeFileList -ComposeFiles $withPlatform -HasSourceModules $true) | Should -Contain $modules
        [string[]](Update-ComposeFileList -ComposeFiles $base -HasSourceModules $true) | Should -Not -Contain $modules
        [string[]](Update-ComposeFileList -ComposeFiles $withPlatform -HasSourceModules $false) | Should -Not -Contain $modules
    }

    It 'every docker-compose*.yml in the repo is in the catalog' {
        $repositoryRoot = Get-TestRepositoryRoot
        $catalogNames = @($script:ComposeFileCatalog | ForEach-Object { $_.Name })
        $repositoryFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Filter 'docker-compose*.yml' -File | ForEach-Object { $_.Name })
        $repositoryFiles.Count | Should -BeGreaterThan 0
        foreach ($name in $repositoryFiles) {
            $catalogNames | Should -Contain $name
        }
    }
}
