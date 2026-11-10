# The COMPOSE_FILE catalog and its normalization.
#
# COMPOSE_FILE lists the compose files of the stack. Users and switches pick feature files; the scripts
# maintain link files (wiring two features together) and .https.yml overlays (the HTTPS mode), and keep
# the whole list in the canonical order of $script:ComposeFileCatalog.
#
# Catalog entry: [pscustomobject]@{ Name; Kind; Feature; OverlayOf; Requires; Excludes; Generated }
#   Kind      base | mode | provider | feature | overlay | optin | link
#   Feature   switch key of a provider, feature or opt-in file (postgres, platform, esLimited, ...); else $null
#   OverlayOf Name of the file an overlay belongs to; else $null
#   Requires  Names that must be emitted for this file to stay listed (a feature or opt-in without them is
#             dropped with a warning; a link without them is simply not added)
#   Excludes  Names that must not be emitted for a link to be added
#   Generated $true when a script writes the file (it is emitted only on request)

$script:ComposeFileCatalog = & {
    function New-ComposeCatalogEntry {
        param(
            [string]$Suffix,
            [string]$Kind,
            [string]$Feature,
            [string]$OverlayOf,
            [string[]]$Requires = @(),
            [string[]]$Excludes = @(),
            [bool]$Generated = $false
        )

        $toName = { param($part) if ($part -eq 'yml') { 'docker-compose.yml' } else { "docker-compose.$part" } }
        [pscustomobject]@{
            Name      = & $toName $Suffix
            Kind      = $Kind
            Feature   = if ($Feature) { $Feature } else { $null }
            OverlayOf = if ($OverlayOf) { & $toName $OverlayOf } else { $null }
            Requires  = [string[]]@($Requires | ForEach-Object { & $toName $_ })
            Excludes  = [string[]]@($Excludes | ForEach-Object { & $toName $_ })
            Generated = $Generated
        }
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $entries.Add((New-ComposeCatalogEntry 'yml' 'base'))
    $entries.Add((New-ComposeCatalogEntry 'https.yml' 'mode'))
    foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
        $entries.Add((New-ComposeCatalogEntry "$provider.yml" 'provider' -Feature $provider))
    }
    $entries.Add((New-ComposeCatalogEntry 'platform.yml' 'feature' -Feature 'platform'))
    $entries.Add((New-ComposeCatalogEntry 'platform.https.yml' 'overlay' -OverlayOf 'platform.yml'))
    $entries.Add((New-ComposeCatalogEntry 'elasticsearch.yml' 'feature' -Feature 'elasticsearch'))
    $entries.Add((New-ComposeCatalogEntry 'elasticsearch.https.yml' 'overlay' -OverlayOf 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'es-limited.yml' 'optin' -Feature 'esLimited' -Requires 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'kibana.yml' 'feature' -Feature 'kibana' -Requires 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'kibana.https.yml' 'overlay' -OverlayOf 'kibana.yml'))
    $entries.Add((New-ComposeCatalogEntry 'redis.yml' 'feature' -Feature 'redis'))
    $entries.Add((New-ComposeCatalogEntry 'frontend.yml' 'feature' -Feature 'frontend'))
    $entries.Add((New-ComposeCatalogEntry 'frontend.https.yml' 'overlay' -OverlayOf 'frontend.yml'))
    foreach ($provider in 'postgres', 'mysql', 'sqlserver') {
        $entries.Add((New-ComposeCatalogEntry "platform-$provider.yml" 'link' -Requires 'platform.yml', "$provider.yml"))
    }
    $entries.Add((New-ComposeCatalogEntry 'platform-elasticsearch.yml' 'link' -Requires 'platform.yml', 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'platform-elasticsearch.https.yml' 'overlay' -OverlayOf 'platform-elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'platform-redis.yml' 'link' -Requires 'platform.yml', 'redis.yml'))
    $entries.Add((New-ComposeCatalogEntry 'platform-frontend.yml' 'link' -Requires 'platform.yml', 'frontend.yml'))
    $entries.Add((New-ComposeCatalogEntry 'platform-modules.yml' 'link' -Requires 'platform.yml' -Generated $true))
    $entries.Add((New-ComposeCatalogEntry 'kibana-elasticsearch.yml' 'link' -Requires 'kibana.yml', 'elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'kibana-elasticsearch.https.yml' 'overlay' -OverlayOf 'kibana-elasticsearch.yml'))
    $entries.Add((New-ComposeCatalogEntry 'frontend-hostplatform.yml' 'link' -Requires 'frontend.yml' -Excludes 'platform.yml'))
    , $entries.ToArray()
}

$script:ComposeHttpsFile = 'docker-compose.https.yml'
$script:ComposeModulesFile = 'docker-compose.platform-modules.yml'

function Get-ComposeFileList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value,
        [Parameter(Position = 1)][string]$Separator = ';'
    )

    $files = $Value.Split($Separator) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    # The unary comma keeps an empty or single-item list an array through the pipeline.
    , [string[]]@($files)
}

function ConvertTo-ComposeFileValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Position = 1)][string]$Separator = ';'
    )

    $ComposeFiles -join $Separator
}

function Get-ComposeFeatures {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $known = @($script:ComposeFileCatalog | ForEach-Object { $_.Name })
    $isListed = { param($name) $ComposeFiles -ccontains $name }
    [pscustomobject]@{
        Provider      = Resolve-DbProvider -ComposeFiles $ComposeFiles
        Platform      = & $isListed 'docker-compose.platform.yml'
        Elasticsearch = & $isListed 'docker-compose.elasticsearch.yml'
        Kibana        = & $isListed 'docker-compose.kibana.yml'
        Redis         = & $isListed 'docker-compose.redis.yml'
        Frontend      = & $isListed 'docker-compose.frontend.yml'
        Https         = & $isListed $script:ComposeHttpsFile
        EsLimited     = & $isListed 'docker-compose.es-limited.yml'
        Unknown       = [string[]]@($ComposeFiles | Where-Object { $known -cnotcontains $_ })
    }
}

function Resolve-DbProvider {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    $providers = @($script:ComposeFileCatalog |
            Where-Object { $_.Kind -eq 'provider' -and $ComposeFiles -ccontains $_.Name } |
            ForEach-Object { $_.Feature })
    if ($providers.Count -gt 1) {
        throw [System.InvalidOperationException]::new(
            "COMPOSE_FILE lists more than one database provider: $($providers -join ', '). List exactly one.")
    }
    if ($providers.Count -eq 0) {
        return $null
    }
    $providers[0]
}

function Update-ComposeFileList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][bool]$HasSourceModules
    )

    $listed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ComposeFiles), [System.StringComparer]::Ordinal)
    $emitted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $result = [System.Collections.Generic.List[string]]::new()
    $httpsMode = $listed.Contains($script:ComposeHttpsFile)

    foreach ($entry in $script:ComposeFileCatalog) {
        $missing = @($entry.Requires | Where-Object { -not $emitted.Contains($_) })
        $emit = switch ($entry.Kind) {
            'base' { $true }
            'mode' { $listed.Contains($entry.Name) }
            { $_ -in 'provider', 'feature', 'optin' } {
                if ($listed.Contains($entry.Name) -and $missing.Count -gt 0) {
                    Write-Warning "$($entry.Name) needs $($missing -join ', ') in COMPOSE_FILE; dropped it."
                }
                $listed.Contains($entry.Name) -and $missing.Count -eq 0
            }
            'link' {
                $excluded = @($entry.Excludes | Where-Object { $emitted.Contains($_) })
                $missing.Count -eq 0 -and $excluded.Count -eq 0 -and (-not $entry.Generated -or $HasSourceModules)
            }
            'overlay' { $httpsMode -and $emitted.Contains($entry.OverlayOf) }
        }
        if ($emit) {
            $null = $emitted.Add($entry.Name)
            $result.Add($entry.Name)
        }
    }

    $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@($script:ComposeFileCatalog | ForEach-Object { $_.Name }), [System.StringComparer]::Ordinal)
    foreach ($file in $ComposeFiles) {
        if (-not $known.Contains($file)) {
            $result.Add($file)
        }
    }

    , $result.ToArray()
}

function Test-ComposeHasSourceModules {
    param([string[]]$ComposeFiles)

    $ComposeFiles -ccontains $script:ComposeModulesFile
}

function Set-ComposeFile {
    # Adds or removes one file, then normalizes. The generated platform-modules file keeps its state.
    param(
        [string[]]$ComposeFiles,
        [string]$Name,
        [bool]$Enabled
    )

    $files = @($ComposeFiles | Where-Object { $_ -cne $Name })
    if ($Enabled) {
        $files += $Name
    }
    Update-ComposeFileList -ComposeFiles $files -HasSourceModules (Test-ComposeHasSourceModules $ComposeFiles)
}

function Set-ComposeFeature {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][ValidateSet('platform', 'elasticsearch', 'kibana', 'redis', 'frontend', 'esLimited')][string]$Feature,
        [Parameter(Mandatory, Position = 2)][bool]$Enabled
    )

    $entry = $script:ComposeFileCatalog |
        Where-Object { $_.Kind -in 'feature', 'optin' -and $_.Feature -eq $Feature } |
        Select-Object -First 1
    Set-ComposeFile -ComposeFiles $ComposeFiles -Name $entry.Name -Enabled $Enabled
}

function Set-ComposeProvider {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][ValidateSet('postgres', 'mysql', 'sqlserver')][string]$Provider
    )

    $providerNames = @($script:ComposeFileCatalog | Where-Object { $_.Kind -eq 'provider' } | ForEach-Object { $_.Name })
    $others = @($ComposeFiles | Where-Object { $providerNames -cnotcontains $_ })
    $name = ($script:ComposeFileCatalog | Where-Object { $_.Kind -eq 'provider' -and $_.Feature -eq $Provider }).Name
    Update-ComposeFileList -ComposeFiles (@($others) + $name) -HasSourceModules (Test-ComposeHasSourceModules $ComposeFiles)
}

function Set-ComposeHttps {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$ComposeFiles,
        [Parameter(Mandatory, Position = 1)][bool]$Enabled
    )

    Set-ComposeFile -ComposeFiles $ComposeFiles -Name $script:ComposeHttpsFile -Enabled $Enabled
}

function Get-DefaultComposeFiles {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('postgres', 'mysql', 'sqlserver')][string]$Provider,
        [Parameter(Position = 1)][bool]$Https = $true
    )

    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add('docker-compose.yml')
    if ($Https) {
        $names.Add($script:ComposeHttpsFile)
    }
    $names.Add("docker-compose.$Provider.yml")
    foreach ($feature in 'platform', 'elasticsearch', 'kibana', 'redis', 'frontend') {
        $names.Add("docker-compose.$feature.yml")
    }
    Update-ComposeFileList -ComposeFiles $names.ToArray() -HasSourceModules $false
}

function Get-ComposeProjectName {
    # Compose's default project name for a folder: lowercase, [a-z0-9_-] only, no leading '_' or '-'.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$FolderPath
    )

    $leaf = [System.IO.Path]::GetFileName($FolderPath.TrimEnd('/', '\'))
    $name = ($leaf.ToLowerInvariant() -replace '[^a-z0-9_-]', '').TrimStart('_', '-')
    if (-not $name) {
        throw [System.ArgumentException]::new("No valid Compose project name can be derived from the folder '$FolderPath'.", 'FolderPath')
    }
    $name
}

function Get-SolutionVolumeNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Prefix
    )

    $suffixes = 'postgres_data', 'mysql_data', 'mssql_data', 'cms-content-data', 'modules-data', 'esdata01', 'redisdata', 'certs'
    , [string[]]@($suffixes | ForEach-Object { "${Prefix}_$_" })
}

function Get-SolutionImageNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ProjectName
    )

    , [string[]]@("vc-platform:$ProjectName-latest", "vc-frontend:$ProjectName-latest")
}

function Test-RemovableFolder {
    # $false for a folder with a .git entry (a checkout, or a worktree whose .git is a file): the repository root is
    # itself a valid solution folder, and remove must never delete it (P13).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Folder
    )

    -not (Test-Path -LiteralPath (Join-Path $Folder '.git'))
}

function Get-RemovalPlan {
    # What remove.ps1 does to a solution folder: the `docker compose` arguments, the volumes and images to delete
    # by name, and the paths to delete. The volume prefix and image tag follow the compose files:
    # VOLUME_PREFIX, else the project name (COMPOSE_PROJECT_NAME, else the folder name).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Folder,
        [Parameter(Mandatory, Position = 1)][bool]$KeepData
    )

    $envPath = Join-Path $Folder '.env'
    $volumePrefix = $null
    $projectName = $null
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        $document = Read-EnvFile -Path $envPath
        $volumePrefix = Get-EnvValue -Document $document -Key 'VOLUME_PREFIX'
        $projectName = Get-EnvValue -Document $document -Key 'COMPOSE_PROJECT_NAME'
    }
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = Get-ComposeProjectName -FolderPath $Folder
    }
    if ([string]::IsNullOrWhiteSpace($volumePrefix)) {
        $volumePrefix = $projectName
    }

    if ($KeepData) {
        $downArgs = [string[]]@('down', '--remove-orphans')
        $volumes = [string[]]@()
        $deletePaths = [string[]]@(Get-ChildItem -LiteralPath $Folder -Force |
                Where-Object { $_.Name -ne '.env' } |
                ForEach-Object { $_.FullName })
    }
    else {
        $downArgs = [string[]]@('down', '-v', '--remove-orphans')
        $volumes = Get-SolutionVolumeNames -Prefix $volumePrefix
        $deletePaths = [string[]]@($Folder)
    }

    [pscustomobject]@{
        DownArgs    = $downArgs
        Volumes     = $volumes
        Images      = Get-SolutionImageNames -ProjectName $projectName
        DeletePaths = $deletePaths
    }
}
