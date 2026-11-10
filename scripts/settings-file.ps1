# The platform settings derived from .env, for a platform run from source (SPEC §5.3, §7.2).
#
# The compose YAML defines the same settings for the Docker platform; a drift test keeps the two equal.
# Settings are a flat, ordered table keyed like .NET configuration ('Section:Key'). The Container topology
# is what the compose files give the platform (services by name, fixed container ports). The Host topology
# is a platform on the host machine (services on localhost, published ports) and adds the keys only that
# platform needs.

function Get-EnvSettingValue {
    # A .env value, or the default when the key is missing or empty.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Default
    )

    if ($EnvValues.Contains($Key) -and -not [string]::IsNullOrEmpty([string]$EnvValues[$Key])) {
        return [string]$EnvValues[$Key]
    }
    $Default
}

function Get-RequiredEnvSecret {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $EnvValues.Contains($Key) -or [string]::IsNullOrEmpty([string]$EnvValues[$Key])) {
        throw [System.InvalidOperationException]::new("$Key is empty in .env; the platform settings need it.")
    }
    [string]$EnvValues[$Key]
}

function Get-DbSettings {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('postgres', 'mysql', 'sqlserver')][string]$Provider,
        [Parameter(Mandatory, Position = 1)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 2)][ValidateSet('Container', 'Host')][string]$Topology
    )

    $password = Get-RequiredEnvSecret -EnvValues $EnvValues -Key 'DB_PASSWORD'
    $hostSide = $Topology -eq 'Host'
    $server = if ($hostSide) { 'localhost' } else { 'vc-db' }
    $portKey = @{ postgres = 'PGSQL_PORT'; mysql = 'MYSQL_PORT'; sqlserver = 'MSSQL_PORT' }[$Provider]
    $containerPort = @{ postgres = '5432'; mysql = '3306'; sqlserver = '1433' }[$Provider]
    $port = if ($hostSide) { Get-EnvSettingValue -EnvValues $EnvValues -Key $portKey -Default $containerPort } else { $containerPort }

    switch ($Provider) {
        'postgres' {
            $name = 'PostgreSql'
            $connection = "User ID=postgres;Password=$password;Host=$server;Port=$port;Database=VirtoCommerce3"
        }
        'mysql' {
            $name = 'MySql'
            $connection = "Server=$server;Port=$port;Database=VirtoCommerce3;User=root;Password=$password"
        }
        'sqlserver' {
            $name = 'SqlServer'
            $connection = "Server=$server,$port;Database=VirtoCommerce3;User Id=sa;Password=$password;TrustServerCertificate=True"
        }
    }

    [ordered]@{
        'DatabaseProvider'                = $name
        'ConnectionStrings:VirtoCommerce' = $connection
    }
}

function Get-PlatformSettings {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 2)][ValidateSet('Container', 'Host')][string]$Topology,
        [Parameter(Position = 3)][string]$CaFingerprint
    )

    $features = Get-ComposeFeatures -ComposeFiles $ComposeFiles
    if (-not $features.Provider) {
        throw [System.InvalidOperationException]::new('COMPOSE_FILE lists no database provider. List exactly one of docker-compose.postgres.yml, docker-compose.mysql.yml, docker-compose.sqlserver.yml.')
    }

    $hostSide = $Topology -eq 'Host'
    $scheme = if ($features.Https) { 'https' } else { 'http' }
    $platformPort = Get-EnvSettingValue -EnvValues $EnvValues -Key 'PLATFORM_PORT' -Default '8090'

    $settings = Get-DbSettings -Provider $features.Provider -EnvValues $EnvValues -Topology $Topology
    $settings['VirtoCommerce:AllowInsecureHttp'] = if ($features.Https) { 'false' } else { 'true' }
    $settings['VirtoCommerce:Hangfire:JobStorageType'] = 'Memory'
    $settings['Assets:FileSystem:PublicUrl'] = "${scheme}://localhost:$platformPort/assets/"
    $settings['Content:FileSystem:PublicUrl'] = "${scheme}://localhost:$platformPort/cms-content/"

    if ($features.Elasticsearch) {
        $searchProvider = Get-EnvSettingValue -EnvValues $EnvValues -Key 'SEARCH_PROVIDER' -Default 'ElasticSearch8'
        if ($searchProvider -cnotin 'ElasticSearch8', 'ElasticSearch9') {
            throw [System.InvalidOperationException]::new("SEARCH_PROVIDER is '$searchProvider' in .env; use ElasticSearch8 or ElasticSearch9.")
        }
        $server = if ($hostSide) {
            "${scheme}://localhost:$(Get-EnvSettingValue -EnvValues $EnvValues -Key 'ES_PORT' -Default '9200')"
        }
        else {
            "${scheme}://es:9200"
        }
        $settings['Search:Provider'] = $searchProvider
        $settings["Search:${searchProvider}:Server"] = $server
        $settings["Search:${searchProvider}:User"] = 'elastic'
        $settings["Search:${searchProvider}:Key"] = Get-RequiredEnvSecret -EnvValues $EnvValues -Key 'ELASTIC_PASSWORD'
        if ($hostSide -and $CaFingerprint) {
            $settings["Search:${searchProvider}:CertificateFingerprint"] = $CaFingerprint
        }
    }

    if ($features.Redis) {
        $redisServer = if ($hostSide) {
            "localhost:$(Get-EnvSettingValue -EnvValues $EnvValues -Key 'REDIS_PORT' -Default '6379')"
        }
        else {
            'redis:6379'
        }
        $settings['ConnectionStrings:RedisConnectionString'] = "$redisServer,password=$(Get-RequiredEnvSecret -EnvValues $EnvValues -Key 'REDIS_PASSWORD')"
    }

    if ($hostSide) {
        $bindAddress = Get-EnvSettingValue -EnvValues $EnvValues -Key 'BIND_ADDRESS' -Default '127.0.0.1'
        $settings['Kestrel:Endpoints:Main:Url'] = "${scheme}://${bindAddress}:$platformPort"
    }

    $settings
}

function ConvertTo-SettingsJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$Flat
    )

    $root = [ordered]@{}
    foreach ($key in $Flat.Keys) {
        $segments = $key.Split(':')
        $node = $root
        for ($index = 0; $index -lt $segments.Count - 1; $index++) {
            $segment = $segments[$index]
            if (-not $node.Contains($segment)) {
                $node[$segment] = [ordered]@{}
            }
            elseif ($node[$segment] -isnot [System.Collections.IDictionary]) {
                throw [System.InvalidOperationException]::new("Settings key '$key' conflicts with the value of '$($segments[0..$index] -join ':')'.")
            }
            $node = $node[$segment]
        }
        $leaf = $segments[-1]
        if ($node.Contains($leaf) -and $node[$leaf] -is [System.Collections.IDictionary]) {
            throw [System.InvalidOperationException]::new("Settings key '$key' conflicts with the section of the same name.")
        }
        $node[$leaf] = $Flat[$key]
    }
    $root | ConvertTo-Json -Depth 20
}

function Get-SettingsFilePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$PlatformPath,
        [Parameter(Mandatory, Position = 1)][ValidateSet('checkout', 'prebuilt')][string]$Kind
    )

    $fileName = 'VirtoCommerce.Platform.Web.settings.json'
    if ($Kind -eq 'prebuilt') {
        return Join-Path $PlatformPath $fileName
    }
    Join-Path (Join-Path (Join-Path $PlatformPath 'src') 'VirtoCommerce.Platform.Web') $fileName
}

function Get-ContainerOnlyKeys {
    # Compose keys of the Docker platform that the source platform's settings never carry.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    [string[]]@('ASPNETCORE_URLS', 'Kestrel:Certificates:Default:Path', 'Kestrel:Certificates:Default:KeyPath', 'SEARCH_PROVIDER')
}

function Get-HostOnlyKeys {
    # Settings keys only the source platform gets; <provider> stands for the SEARCH_PROVIDER value.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    [string[]]@('Kestrel:Endpoints:Main:Url', 'Search:<provider>:CertificateFingerprint')
}
