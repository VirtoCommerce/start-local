# Preflight checks and the service listing of a stack (SPEC §8.1, §11).
#
# Each check returns a message that names its fix; Invoke-Preflight collects them and the caller prints them.

$script:ComposeMinimumVersion = '2.18.0'

# The .env key of each published port, in the order the file list gives the services, with its standard value.
$script:PortCatalog = @(
    @{ Provider = 'postgres'; Key = 'PGSQL_PORT'; Default = 5432 }
    @{ Provider = 'mysql'; Key = 'MYSQL_PORT'; Default = 3306 }
    @{ Provider = 'sqlserver'; Key = 'MSSQL_PORT'; Default = 1433 }
    @{ File = 'docker-compose.platform.yml'; Key = 'PLATFORM_PORT'; Default = 8090 }
    @{ File = 'docker-compose.elasticsearch.yml'; Key = 'ES_PORT'; Default = 9200 }
    @{ File = 'docker-compose.kibana.yml'; Key = 'KIBANA_PORT'; Default = 5601 }
    @{ File = 'docker-compose.redis.yml'; Key = 'REDIS_PORT'; Default = 6379 }
    @{ File = 'docker-compose.frontend.yml'; Key = 'FRONTEND_PORT'; Default = 443 }
)

function Test-PortInUse {
    # True when a TCP listener on this machine already uses the port.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][int]$Port
    )

    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    @($listeners | Where-Object { $_.Port -eq $Port }).Count -gt 0
}

function Test-DockerRunning {
    # True when the Docker daemon answers.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Get-Command docker -CommandType Application -ErrorAction Ignore)) {
        return $false
    }
    $null = & docker info --format '{{.ServerVersion}}' 2>&1
    $LASTEXITCODE -eq 0
}

function ConvertTo-PublishedPorts {
    # The published host ports in `docker compose ps --format json` output: one JSON object per line
    # (Compose 2.21 and later) or one JSON array (older).
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Json
    )

    $text = ($Json | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) {
        return , [int[]]@()
    }
    $containers = if ($text.TrimStart().StartsWith('[')) {
        $text | ConvertFrom-Json
    }
    else {
        $text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }
    }
    $ports = foreach ($container in $containers) {
        foreach ($publisher in $container.Publishers) {
            if ([int]$publisher.PublishedPort -gt 0) {
                [int]$publisher.PublishedPort
            }
        }
    }
    , [int[]]@($ports | Sort-Object -Unique)
}

function Get-ProjectPublishedPorts {
    # The host ports the running containers of this folder's Compose project publish (run it in the solution folder).
    # Empty when Docker cannot say: the caller then treats every port as foreign.
    [CmdletBinding()]
    [OutputType([int[]])]
    param()

    try {
        $output = & docker compose ps --format json 2>$null
        if ($LASTEXITCODE -ne 0) {
            return , [int[]]@()
        }
        ConvertTo-PublishedPorts -Json ([string[]]@($output))
    }
    catch {
        Write-Verbose "Get-ProjectPublishedPorts: docker compose ps failed: $($_.Exception.Message)"
        , [int[]]@()
    }
}

function Get-RequiredPorts {
    # The host ports the stack needs free: one per listed service (and a source platform), minus ExcludePorts.
    # Returns @{ Key; Port } entries. Throws when a port value is not a number.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Position = 2)][int[]]$ExcludePorts = @()
    )

    $features = Get-ComposeFeatures -ComposeFiles $ComposeFiles
    $sourcePlatform = -not $features.Platform -and
        -not [string]::IsNullOrEmpty([string]$EnvValues['PLATFORM_SOURCE_PATH']) -and
        ([string]$EnvValues['SKIP_PLATFORM']).Trim() -ne 'true'

    $required = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $script:PortCatalog) {
        $needed = if ($entry.Provider) { $features.Provider -eq $entry.Provider }
        elseif ($entry.Key -eq 'PLATFORM_PORT') { $features.Platform -or $sourcePlatform }
        else { $ComposeFiles -ccontains $entry.File }
        if (-not $needed) {
            continue
        }

        $text = Get-EnvSettingValue -EnvValues $EnvValues -Key $entry.Key -Default ([string]$entry.Default)
        $port = 0
        if (-not [int]::TryParse($text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw [System.FormatException]::new("$($entry.Key) is '$text' in .env; it must be a port number from 1 to 65535.")
        }
        if ($ExcludePorts -notcontains $port) {
            $required.Add([pscustomobject]@{ Key = $entry.Key; Port = $port })
        }
    }
    , [pscustomobject[]]$required.ToArray()
}

function Get-ServiceUrls {
    # The URLs of the services a run makes available, as @{ Name; Url }.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $features = Get-ComposeFeatures -ComposeFiles $ComposeFiles
    $scheme = if ($features.Https) { 'https' } else { 'http' }
    $hasPlatform = $features.Platform -or -not [string]::IsNullOrEmpty([string]$EnvValues['PLATFORM_SOURCE_PATH'])

    $services = @(
        @{ Name = 'Platform'; Listed = $hasPlatform; Key = 'PLATFORM_PORT'; Default = '8090' }
        @{ Name = 'Storefront'; Listed = $features.Frontend; Key = 'FRONTEND_PORT'; Default = '443' }
        @{ Name = 'Elasticsearch'; Listed = $features.Elasticsearch; Key = 'ES_PORT'; Default = '9200' }
        @{ Name = 'Kibana'; Listed = $features.Kibana; Key = 'KIBANA_PORT'; Default = '5601' }
    )
    $urls = foreach ($service in $services) {
        if ($service.Listed) {
            $port = Get-EnvSettingValue -EnvValues $EnvValues -Key $service.Key -Default $service.Default
            [pscustomobject]@{ Name = $service.Name; Url = "${scheme}://localhost:$port" }
        }
    }
    , [pscustomobject[]]@($urls)
}

function Invoke-Preflight {
    # Runs the checks and returns the errors, each naming its fix; an empty array means go.
    # Run it in the solution folder: the published-ports query uses its Compose project.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 2)][bool]$NonInteractive
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    try {
        $composeVersion = Get-ComposeVersion
        if (-not (Test-ComposeVersion $composeVersion $script:ComposeMinimumVersion)) {
            $errors.Add("Docker Compose $composeVersion is too old: $($script:ComposeMinimumVersion) or later is required. Update Docker Desktop, or install the Compose plugin v$($script:ComposeMinimumVersion)+ (https://docs.docker.com/compose/install/).")
        }
    }
    catch {
        $errors.Add("'docker compose' (Compose v2) is not available. Install Docker with Compose $($script:ComposeMinimumVersion) or later (https://docs.docker.com/compose/install/).")
    }

    $dockerRunning = Test-DockerRunning
    if (-not $dockerRunning) {
        $errors.Add('Docker is not running. Start Docker Desktop (or the Docker daemon) and run again.')
    }

    $ownPorts = if ($dockerRunning) { Get-ProjectPublishedPorts } else { [int[]]@() }
    $sourcePlatform = Test-SourcePlatformMode -EnvValues $EnvValues -ComposeFiles $ComposeFiles
    if ($sourcePlatform -and (Get-RunningSourcePlatform -LogDir (Get-SourcePlatformLogDir -SolutionFolder (Get-Location).ProviderPath))) {
        # A re-run: the platform this folder started earlier holds its port, and start restarts it.
        $platformPort = 0
        if ([int]::TryParse((Get-EnvSettingValue -EnvValues $EnvValues -Key 'PLATFORM_PORT' -Default '8090').Trim(), [ref]$platformPort)) {
            $ownPorts = [int[]]@($ownPorts + $platformPort)
        }
    }
    foreach ($required in (Get-RequiredPorts -EnvValues $EnvValues -ComposeFiles $ComposeFiles -ExcludePorts $ownPorts)) {
        if (Test-PortInUse -Port $required.Port) {
            $errors.Add("Port $($required.Port) ($($required.Key)) is already in use. Stop the program that uses it, or set another $($required.Key) in .env.")
        }
    }

    $moduleSources = Get-ModuleSourceKind -Paths (Split-ModuleSourcePaths ([string]$EnvValues['MODULE_SOURCE_PATHS']))
    if ($moduleSources.Kind -in 'mixed', 'invalid') {
        $errors.Add($moduleSources.Message)
    }
    elseif ($dockerRunning -and (Get-ComposeFeatures -ComposeFiles $ComposeFiles).Platform) {
        # Only a Docker platform bind-mounts the sources (SPEC §7.3), and Docker Desktop refuses folders outside its File Sharing list.
        foreach ($mount in (Get-ModuleMountPlan -Classification $moduleSources)) {
            try {
                $shared = Test-FileSharing -Path $mount.Source
            }
            catch {
                $errors.Add("File sharing: could not check whether Docker can mount '$($mount.Source)' (MODULE_SOURCE_PATHS): $($_.Exception.Message)")
                continue
            }
            if (-not $shared) {
                $errors.Add("File sharing: Docker cannot mount '$($mount.Source)' (MODULE_SOURCE_PATHS). Add its folder to Docker Desktop > Settings > Resources > File sharing, then run again.")
            }
        }
    }

    if ($sourcePlatform) {
        $platformPath = Resolve-PlatformSourcePath -Value ([string]$EnvValues['PLATFORM_SOURCE_PATH'])
        $platformKind = Get-PlatformSourceKind -Path $platformPath
        if (-not $platformKind) {
            $errors.Add("PLATFORM_SOURCE_PATH '$platformPath' is neither a vc-platform checkout (it has no src/VirtoCommerce.Platform.Web/VirtoCommerce.Platform.Web.csproj) nor a prebuilt platform folder (it has no VirtoCommerce.Platform.Web.dll). Fix the path in .env.")
        }
        else {
            # H6: start only runs what is built. A skipped platform is built and run by the user (B6).
            $contentRoot = Get-PlatformContentRoot -Path $platformPath -Kind $platformKind
            if (([string]$EnvValues['SKIP_PLATFORM']).Trim() -ne 'true' -and -not (Test-PlatformBuildOutput -Path $platformPath -Kind $platformKind)) {
                $errors.Add("The platform is not built: '$contentRoot' has no build output (bin/**/VirtoCommerce.Platform.Web.dll). Build it with dotnet build or from your IDE, then run again.")
            }
            $linkPlan = Get-ModuleLinkPlan -Classification $moduleSources -ContentRoot $contentRoot
            if ($linkPlan.Count -gt 0 -and -not (Test-SymlinkRights)) {
                $errors.Add('MODULE_SOURCE_PATHS needs directory symlinks, which this shell cannot create. Enable Developer Mode or run an elevated shell, then run again.')
            }
        }
    }

    if ($NonInteractive) {
        foreach ($key in (Get-MissingRequiredKeys -EnvValues $EnvValues)) {
            $errors.Add("$key is empty in .env. Set it, or pass the matching parameter.")
        }
    }

    , $errors.ToArray()
}
