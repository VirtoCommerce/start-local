# Modules from source (SPEC §7.1, §7.3, H2): reading MODULE_SOURCE_PATHS and mounting it into the Docker platform.
#
# MODULE_SOURCE_PATHS holds either module *.Web folders (each has a module.manifest) or exactly one modules folder.

$script:PlatformModulesTarget = '/opt/virtocommerce/platform/modules'
$script:PlatformServiceName = 'vc-platform-web'

function Split-ModuleSourcePaths {
    # The entries of a ;-separated MODULE_SOURCE_PATHS value, trimmed, without empty ones.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Value
    )

    $entries = @(([string]$Value) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    , [string[]]$entries
}

function Get-ModuleIdFromManifestText {
    # The module id in the text of a module.manifest, or $null when there is none or it is not a plain id.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text
    )

    try {
        $manifest = [xml]$Text
    }
    catch [System.Management.Automation.RuntimeException] {
        # The [xml] cast reports malformed text as a RuntimeException wrapping the XmlException.
        return $null
    }
    $idNode = $manifest.SelectSingleNode('/*[local-name()="module"]/*[local-name()="id"]')
    if ($null -eq $idNode) {
        return $null
    }
    $id = $idNode.InnerText.Trim()
    # The id becomes a folder name inside the container, so it must be one plain segment.
    if ($id -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.\-]*$') {
        return $null
    }
    $id
}

function Get-ModuleSourceEntry {
    # One MODULE_SOURCE_PATHS entry as @{ Path; Kind; ModuleId }. Path is absolute (relative to the current folder).
    # Kind: web (a *.Web folder), modules (a modules folder), missing (not a folder), manifest (a module.manifest without an id).
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path, (Get-Location).ProviderPath)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }

    $kind = 'modules'
    $moduleId = $null
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        $kind = 'missing'
    }
    else {
        $manifestPath = Join-Path $fullPath 'module.manifest'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $kind = 'web'
            try {
                $moduleId = Get-ModuleIdFromManifestText -Text (Get-Content -LiteralPath $manifestPath -Raw)
            }
            catch [System.IO.IOException], [System.UnauthorizedAccessException] {
                $moduleId = $null
            }
            if ($null -eq $moduleId) {
                $kind = 'manifest'
            }
        }
    }
    [pscustomobject]@{ Path = $fullPath; Kind = $kind; ModuleId = $moduleId }
}

function Get-ModuleSourceKind {
    # Classifies MODULE_SOURCE_PATHS: @{ Kind; Entries; Message }.
    # Kind: none, webfolders, modulesfolder, mixed (both forms) or invalid (anything else wrong); Message says what to fix.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$Paths
    )

    $entries = @($Paths | ForEach-Object { Get-ModuleSourceEntry -Path $_ })
    $result = { param([string]$Kind, [string]$Message) [pscustomobject]@{ Kind = $Kind; Entries = $entries; Message = $Message } }

    if ($entries.Count -eq 0) {
        return & $result 'none' ''
    }

    $missing = @($entries | Where-Object { $_.Kind -eq 'missing' })
    if ($missing.Count -gt 0) {
        return & $result 'invalid' "MODULE_SOURCE_PATHS has a path that is not a folder: $(($missing | ForEach-Object { $_.Path }) -join ', '). Fix the path in .env."
    }
    $noId = @($entries | Where-Object { $_.Kind -eq 'manifest' })
    if ($noId.Count -gt 0) {
        return & $result 'invalid' "MODULE_SOURCE_PATHS has a module.manifest without a usable module id: $(($noId | ForEach-Object { Join-Path $_.Path 'module.manifest' }) -join ', '). Fix the manifest or the path in .env."
    }

    $webFolders = @($entries | Where-Object { $_.Kind -eq 'web' })
    $modulesFolders = @($entries | Where-Object { $_.Kind -eq 'modules' })
    if ($webFolders.Count -gt 0 -and $modulesFolders.Count -gt 0) {
        return & $result 'mixed' 'MODULE_SOURCE_PATHS mixes module *.Web folders (they have a module.manifest) with a modules folder. List either the *.Web folders or exactly one modules folder in .env.'
    }
    if ($modulesFolders.Count -gt 1) {
        return & $result 'invalid' 'MODULE_SOURCE_PATHS lists several modules folders. List exactly one modules folder, or the module *.Web folders, in .env.'
    }
    $duplicate = @($webFolders | Group-Object -Property ModuleId -CaseSensitive | Where-Object { $_.Count -gt 1 })
    if ($duplicate.Count -gt 0) {
        return & $result 'invalid' "MODULE_SOURCE_PATHS lists module id $($duplicate[0].Name) more than once. Keep one folder per module in .env."
    }

    if ($webFolders.Count -gt 0) {
        return & $result 'webfolders' ''
    }
    & $result 'modulesfolder' ''
}

function Get-ModuleMountPlan {
    # The bind mounts a Docker platform needs, as @{ Source; Target }; empty unless the classification is webfolders or modulesfolder.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Classification
    )

    $plan = [System.Collections.Generic.List[object]]::new()
    switch ($Classification.Kind) {
        'webfolders' {
            foreach ($entry in $Classification.Entries) {
                $plan.Add([pscustomobject]@{ Source = $entry.Path; Target = "$($script:PlatformModulesTarget)/$($entry.ModuleId)" })
            }
        }
        'modulesfolder' {
            $plan.Add([pscustomobject]@{ Source = $Classification.Entries[0].Path; Target = $script:PlatformModulesTarget })
        }
    }
    , [pscustomobject[]]$plan.ToArray()
}

function ConvertTo-ComposeYamlString {
    # A double-quoted YAML scalar. '$' is doubled so that Compose does not interpolate it.
    param([Parameter(Mandatory, Position = 0)][string]$Value)

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace('$', '$$')
    if ($escaped -match '[\r\n]') {
        throw [System.ArgumentException]::new('A path with a line break cannot be mounted.', 'Value')
    }
    '"' + $escaped + '"'
}

function New-ModulesComposeYaml {
    # The content of docker-compose.platform-modules.yml: one bind mount per plan entry. Compose merges volumes by target,
    # so a mount at the modules folder itself replaces the modules-data volume of docker-compose.platform.yml.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][pscustomobject[]]$MountPlan
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by start.ps1 from MODULE_SOURCE_PATHS. Do not edit; it is rewritten on every start.')
    $lines.Add('services:')
    $lines.Add("  $($script:PlatformServiceName):")
    $lines.Add('    volumes:')
    foreach ($mount in $MountPlan) {
        $lines.Add('      - type: bind')
        $lines.Add("        source: $(ConvertTo-ComposeYamlString $mount.Source)")
        $lines.Add("        target: $(ConvertTo-ComposeYamlString $mount.Target)")
    }
    ($lines -join "`n") + "`n"
}

function Write-ModulesComposeFile {
    # Writes docker-compose.platform-modules.yml into the solution folder, or deletes it when the plan is empty.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$SolutionFolder,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][pscustomobject[]]$MountPlan
    )

    $path = Join-Path $SolutionFolder $script:ComposeModulesFile
    if ($MountPlan.Count -eq 0) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Ignore
        return
    }
    [System.IO.File]::WriteAllText($path, (New-ModulesComposeYaml -MountPlan $MountPlan), [System.Text.UTF8Encoding]::new($false))
}

function Test-FileSharing {
    # True when Docker can bind-mount the folder. False when Docker Desktop refuses it ('mounts denied': the folder is not in
    # its File Sharing list, fact check §14). Throws when the probe fails for another reason.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("Folder '$Path' does not exist.")
    }
    $output = & docker run --rm -v "${Path}:/x:ro" alpine true 2>&1
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    $text = ($output | Out-String).Trim()
    if ($text -match 'mounts denied') {
        return $false
    }
    throw [System.InvalidOperationException]::new("docker run failed with exit code $LASTEXITCODE while checking file sharing for '$Path': $text")
}
