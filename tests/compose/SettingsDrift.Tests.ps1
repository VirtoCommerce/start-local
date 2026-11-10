# Keeps the compose YAML and Get-PlatformSettings equal (SPEC §5.3): both define the Docker platform's settings from one .env.
BeforeDiscovery {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)

    # 3 providers x Elasticsearch on/off x Redis on/off, in HTTP and in HTTPS mode, with a platform.
    $script:cases = foreach ($https in $false, $true) {
    foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
        foreach ($elasticsearch in $false, $true) {
            foreach ($redis in $false, $true) {
                $requested = [System.Collections.Generic.List[string]]::new()
                $requested.Add('docker-compose.yml')
                if ($https) { $requested.Add('docker-compose.https.yml') }
                $requested.Add("docker-compose.$provider.yml")
                $requested.Add('docker-compose.platform.yml')
                if ($elasticsearch) { $requested.Add('docker-compose.elasticsearch.yml') }
                if ($redis) { $requested.Add('docker-compose.redis.yml') }
                @{
                    Label        = (@($provider) + @(if ($elasticsearch) { 'elasticsearch' }) + @(if ($redis) { 'redis' }) + @(if ($https) { 'https' })) -join '+'
                    ComposeFiles = [string[]](Update-ComposeFileList -ComposeFiles $requested.ToArray() -HasSourceModules $false)
                }
            }
        }
    }
    }
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"
}

Describe 'Platform settings drift' -Tag 'Compose' -Skip:(-not $script:hasDocker) {
    Context '<Label>' -ForEach $script:cases {
        BeforeAll {
            $folder = New-ComposeFixtureFolder -ComposeFiles $ComposeFiles
            try {
                $config = Invoke-ComposeConfigJson $folder
                $envValues = Get-EnvTable (Read-EnvFile (Join-Path $folder '.env'))
            }
            finally {
                Remove-Item -LiteralPath (Split-Path $folder -Parent) -Recurse -Force -ErrorAction SilentlyContinue
            }

            # Environment variable names spell the configuration separator as '__'.
            $script:composeSettings = [ordered]@{}
            foreach ($variable in $config.services.'vc-platform-web'.environment.PSObject.Properties) {
                $script:composeSettings[$variable.Name.Replace('__', ':')] = [string]$variable.Value
            }
            $script:functionSettings = Get-PlatformSettings -EnvValues $envValues -ComposeFiles $ComposeFiles -Topology Container
            $script:containerOnlyKeys = Get-ContainerOnlyKeys
        }

        It 'every key of the settings function is in the compose environment with an equal value' {
            foreach ($key in $script:functionSettings.Keys) {
                $script:composeSettings.Contains($key) | Should -BeTrue -Because "compose lacks $key"
                $script:composeSettings[$key] | Should -BeExactly $script:functionSettings[$key] -Because "value of $key"
            }
        }

        It 'every compose key outside the container-only keys is in the settings function' {
            foreach ($key in $script:composeSettings.Keys) {
                if ($script:containerOnlyKeys -contains $key) {
                    continue
                }
                $script:functionSettings.Contains($key) | Should -BeTrue -Because "the settings function lacks $key"
            }
        }
    }
}
