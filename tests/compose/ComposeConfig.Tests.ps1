BeforeDiscovery {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)

    # 3 providers x Elasticsearch on/off x Kibana (with Elasticsearch only) x Redis on/off x es-limited (with Elasticsearch only), HTTP mode.
    $script:cases = foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
        foreach ($elasticsearch in $false, $true) {
            foreach ($kibana in ($(if ($elasticsearch) { $false, $true } else { $false }))) {
                foreach ($esLimited in ($(if ($elasticsearch) { $false, $true } else { $false }))) {
                    foreach ($redis in $false, $true) {
                        $requested = [System.Collections.Generic.List[string]]::new()
                        $requested.Add('docker-compose.yml')
                        $requested.Add("docker-compose.$provider.yml")
                        $features = [ordered]@{ elasticsearch = $elasticsearch; kibana = $kibana; redis = $redis; 'es-limited' = $esLimited }
                        foreach ($feature in $features.Keys) {
                            if ($features[$feature]) {
                                $requested.Add("docker-compose.$feature.yml")
                            }
                        }
                        $label = (@($provider) + @($features.Keys | Where-Object { $features[$_] })) -join '+'
                        @{
                            Label         = $label
                            Provider      = $provider
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

Describe 'Compose files' -Tag 'Compose' {
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
