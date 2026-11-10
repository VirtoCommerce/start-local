# Migration of a solution folder from layout 1 (DB_PROVIDER, fixed volume and image names) to layout 2
# (COMPOSE_FILE, VOLUME_PREFIX, per-project image tags). Keyed on START_LOCAL_LAYOUT; a missing key means layout 1.
# Every entry script runs Invoke-StartLocalMigration first. It is idempotent and changes only .env and Docker image tags.

$script:LayoutOneProviders = 'postgres', 'mysql', 'sqlserver'
# Keys layout 2 no longer reads (C6); DB_PROVIDER goes after it has been turned into COMPOSE_FILE.
$script:LayoutOneRemovedKeys = 'DB_PROVIDER', 'ES_CLUSTER_NAME', 'ES_LICENSE'
$script:LayoutOneImages = 'vc-platform', 'vc-frontend'

function Get-EnvLayout {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    $value = Get-EnvValue -Document $Document -Key 'START_LOCAL_LAYOUT'
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 1
    }
    $layout = 0
    if (-not [int]::TryParse($value, [ref]$layout)) {
        throw [System.InvalidOperationException]::new("START_LOCAL_LAYOUT in .env is '$value'; expected a number.")
    }
    $layout
}

function Convert-EnvToLayout2 {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][psobject]$Template
    )

    $changes = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $result = { [pscustomobject]@{ Document = $Document; Changes = [string[]]$changes.ToArray(); Notes = [string[]]$notes.ToArray() } }

    if ((Get-EnvLayout -Document $Document) -ge 2) {
        return & $result
    }

    # Validate before the first change, so a failed migration leaves the document as it was.
    $provider = Get-EnvValue -Document $Document -Key 'DB_PROVIDER'
    if ($script:LayoutOneProviders -cnotcontains $provider) {
        $shown = if ([string]::IsNullOrWhiteSpace($provider)) { 'missing' } else { "'$provider'" }
        throw [System.InvalidOperationException]::new(
            "DB_PROVIDER in .env is $shown; expected one of: $($script:LayoutOneProviders -join ', '). Fix it and run the script again.")
    }

    # Template keys first, so the migrated keys sit where .env.example puts them; the steps below then set their values.
    foreach ($key in (Add-MissingEnvKeys -Document $Document -Template $Template)) {
        $changes.Add("Added $key")
    }

    $composeFile = ConvertTo-ComposeFileValue (Get-DefaultComposeFiles -Provider $provider -Https $false)
    Set-EnvValue -Document $Document -Key 'COMPOSE_FILE' -Value $composeFile
    $changes.Add("Set COMPOSE_FILE=$composeFile (from DB_PROVIDER=$provider)")

    if ((Get-EnvValue -Document $Document -Key 'COMPOSE_PATH_SEPARATOR') -cne ';') {
        Set-EnvValue -Document $Document -Key 'COMPOSE_PATH_SEPARATOR' -Value ';'
        $changes.Add('Set COMPOSE_PATH_SEPARATOR=;')
    }
    if ([string]::IsNullOrEmpty((Get-EnvValue -Document $Document -Key 'VOLUME_PREFIX'))) {
        # Existing volumes keep their virto_* names (D3).
        Set-EnvValue -Document $Document -Key 'VOLUME_PREFIX' -Value 'virto'
        $changes.Add('Set VOLUME_PREFIX=virto')
    }

    foreach ($key in $script:LayoutOneRemovedKeys) {
        if (Remove-EnvKey -Document $Document -Key $key) {
            $changes.Add("Removed $key")
        }
    }

    Set-EnvValue -Document $Document -Key 'START_LOCAL_LAYOUT' -Value '2'
    $changes.Add('Set START_LOCAL_LAYOUT=2')

    $notes.Add('This folder keeps running in HTTP mode, so its URLs stay the same.')
    $notes.Add("Published ports now bind to $(Get-EnvValue -Document $Document -Key 'BIND_ADDRESS') only. To reach the stack from other machines again, set BIND_ADDRESS=0.0.0.0 in .env.")
    $notes.Add('Redis is now a cache without a volume. The old virto_redisdata volume is left alone; a full remove deletes it.')

    & $result
}

function Get-LayoutMigrationImageRetags {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory, Position = 0)][string]$ProjectName)

    [pscustomobject[]]@($script:LayoutOneImages | ForEach-Object {
            [pscustomobject]@{ From = "${_}:local-latest"; To = "${_}:$ProjectName-latest" }
        })
}

function Test-DockerImage {
    # $false when the image is missing, or when the docker CLI is not installed (nothing to retag).
    # Throws when the daemon cannot be asked: `docker image ls -q` exits 0 with empty output for a missing image
    # and non-zero for an unreachable daemon, so "no image" and "cannot tell" stay apart.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
        return $false
    }
    $output = docker image ls -q $Name 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new(
            "The Docker daemon is unreachable, so image $Name could not be checked: $output. The migration will retry once Docker runs.")
    }
    -not [string]::IsNullOrWhiteSpace(($output | Out-String))
}

function Invoke-DockerTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Source,
        [Parameter(Mandatory, Position = 1)][string]$Target
    )

    $output = docker tag $Source $Target 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("docker tag $Source $Target failed: $output")
    }
}

function Invoke-StartLocalMigration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory, Position = 0)][string]$SolutionFolder)

    $envPath = Join-Path $SolutionFolder '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        return $null
    }

    $templatePath = Join-Path $SolutionFolder '.env.example'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        $templatePath = Join-Path $PSScriptRoot '../.env.example'
    }
    $migration = Convert-EnvToLayout2 -Document (Read-EnvFile -Path $envPath) -Template (Read-EnvFile -Path $templatePath)

    $retagged = [System.Collections.Generic.List[string]]::new()
    if ($migration.Changes.Count -gt 0) {
        # Retag before writing .env: a failed retag or an unreachable daemon leaves layout 1, so the next run tries again.
        $projectName = Get-ComposeProjectName -FolderPath $SolutionFolder
        foreach ($pair in (Get-LayoutMigrationImageRetags -ProjectName $projectName)) {
            if ($pair.From -ne $pair.To -and (Test-DockerImage -Name $pair.From) -and -not (Test-DockerImage -Name $pair.To)) {
                Invoke-DockerTag -Source $pair.From -Target $pair.To
                $retagged.Add("$($pair.From) -> $($pair.To)")
            }
        }
        Write-EnvFile -Document $migration.Document -Path $envPath

        Write-Host 'Migrated .env to layout 2:'
        foreach ($change in $migration.Changes) { Write-Host "  $change" }
        foreach ($tag in $retagged) { Write-Host "  Retagged $tag" }
        foreach ($note in $migration.Notes) { Write-Host $note }
    }

    [pscustomobject]@{
        Changes  = $migration.Changes
        Notes    = $migration.Notes
        Retagged = [string[]]$retagged.ToArray()
    }
}
