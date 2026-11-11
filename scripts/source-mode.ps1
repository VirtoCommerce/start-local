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

# --- Platform from source (SPEC §7.1, §7.2) ---

$script:PlatformWebName = 'VirtoCommerce.Platform.Web'
$script:SourcePlatformPidFileName = 'platform.pid'
$script:SourcePlatformLogFileName = 'platform.log'
# Process.StartTime of one process differs by about a tenth of a millisecond between two .NET processes on Linux, so
# the start time in the pid file matches within this window.
$script:StartTimeToleranceTicks = [TimeSpan]::FromSeconds(2).Ticks

function Test-SourcePlatformMode {
    # True when the platform runs from source: PLATFORM_SOURCE_PATH is set and COMPOSE_FILE lists no Docker platform (H4).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][System.Collections.IDictionary]$EnvValues,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$ComposeFiles
    )

    -not ($ComposeFiles -ccontains 'docker-compose.platform.yml') -and
        -not [string]::IsNullOrWhiteSpace([string]$EnvValues['PLATFORM_SOURCE_PATH'])
}

function Resolve-PlatformSourcePath {
    # PLATFORM_SOURCE_PATH as an absolute path, relative to the current folder, without a trailing separator.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Value
    )

    (Get-ModuleSourceEntry -Path $Value.Trim()).Path
}

function Get-PlatformSourceKind {
    # 'checkout' (a vc-platform checkout), 'prebuilt' (a folder with VirtoCommerce.Platform.Web.dll), or $null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path
    )

    $checkoutProject = Join-Path (Join-Path (Join-Path $Path 'src') $script:PlatformWebName) "$($script:PlatformWebName).csproj"
    if (Test-Path -LiteralPath $checkoutProject -PathType Leaf) {
        return 'checkout'
    }
    if (Test-Path -LiteralPath (Join-Path $Path "$($script:PlatformWebName).dll") -PathType Leaf) {
        return 'prebuilt'
    }
    $null
}

function Get-PlatformContentRoot {
    # The folder the platform runs in: its content root and working directory (H5).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][ValidateSet('checkout', 'prebuilt')][string]$Kind
    )

    if ($Kind -eq 'prebuilt') {
        return $Path
    }
    Join-Path (Join-Path $Path 'src') $script:PlatformWebName
}

function Test-PlatformBuildOutput {
    # True when the platform is built: a checkout has bin/**/VirtoCommerce.Platform.Web.dll, a prebuilt folder the dll itself (H6).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][ValidateSet('checkout', 'prebuilt')][string]$Kind
    )

    $contentRoot = Get-PlatformContentRoot -Path $Path -Kind $Kind
    $dllName = "$($script:PlatformWebName).dll"
    if ($Kind -eq 'prebuilt') {
        return Test-Path -LiteralPath (Join-Path $contentRoot $dllName) -PathType Leaf
    }
    $binFolder = Join-Path $contentRoot 'bin'
    if (-not (Test-Path -LiteralPath $binFolder -PathType Container)) {
        return $false
    }
    $null -ne (Get-ChildItem -LiteralPath $binFolder -Filter $dllName -File -Recurse -ErrorAction Ignore | Select-Object -First 1)
}

function Get-SourcePlatformCommand {
    # How start launches the platform: @{ FilePath; Arguments; WorkingDirectory }. The working directory is the content root,
    # where the platform finds its settings file and its modules folder (H5).
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][ValidateSet('checkout', 'prebuilt')][string]$Kind
    )

    $contentRoot = Get-PlatformContentRoot -Path $Path -Kind $Kind
    $arguments = if ($Kind -eq 'checkout') {
        [string[]]@('run', '--no-build', '--project', $contentRoot)
    }
    else {
        [string[]]@("$($script:PlatformWebName).dll")
    }
    [pscustomobject]@{ FilePath = 'dotnet'; Arguments = $arguments; WorkingDirectory = $contentRoot }
}

function Get-ModuleLinkPlan {
    # The symlinks a source platform needs, as @{ LinkPath; Target }; empty unless the classification is webfolders or modulesfolder.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Classification,
        [Parameter(Mandatory, Position = 1)][string]$ContentRoot
    )

    $modulesFolder = Join-Path $ContentRoot 'modules'
    $plan = [System.Collections.Generic.List[object]]::new()
    switch ($Classification.Kind) {
        'webfolders' {
            foreach ($entry in $Classification.Entries) {
                $plan.Add([pscustomobject]@{ LinkPath = Join-Path $modulesFolder $entry.ModuleId; Target = $entry.Path })
            }
        }
        'modulesfolder' {
            $plan.Add([pscustomobject]@{ LinkPath = $modulesFolder; Target = $Classification.Entries[0].Path })
        }
    }
    , [pscustomobject[]]$plan.ToArray()
}

function Set-ModuleLinks {
    # Creates the directory symlinks of the plan. Returns $null on success, else a message naming what stands in the way.
    # A link that already exists is replaced (only the link is removed). A real folder with content is never touched: the
    # message names it, and the user moves it away (H2).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][pscustomobject[]]$LinkPlan
    )

    foreach ($link in $LinkPlan) {
        $parent = Split-Path -Parent $link.LinkPath
        $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Ignore
        if ($parentItem -and $parentItem.LinkTarget) {
            return "'$parent' is a link to '$($parentItem.LinkTarget)', so a module folder cannot be linked inside it. Remove that link, or list one modules folder in MODULE_SOURCE_PATHS."
        }

        $existing = Get-Item -LiteralPath $link.LinkPath -Force -ErrorAction Ignore
        if ($existing -and -not $existing.LinkTarget -and
            -not ($existing.PSIsContainer -and @(Get-ChildItem -LiteralPath $link.LinkPath -Force).Count -eq 0)) {
            return "'$($link.LinkPath)' is a real folder with content, so start cannot link '$($link.Target)' there. Move it away (vc-build installed modules end up there), then run again."
        }
        if ($existing.LinkTarget -and [System.IO.Path]::GetFullPath($existing.LinkTarget, $parent) -ceq [System.IO.Path]::GetFullPath($link.Target)) {
            continue
        }

        try {
            if ($existing) {
                # Deleting the link path itself removes the link and nothing it points to. A link whose target is gone
                # is not a directory any more on Unix, so only a file delete reaches it there.
                if ($existing.LinkTarget -and -not $IsWindows) {
                    [System.IO.File]::Delete($link.LinkPath)
                }
                else {
                    [System.IO.Directory]::Delete($link.LinkPath)
                }
            }
            $null = New-Item -ItemType Directory -Path $parent -Force
            $null = [System.IO.Directory]::CreateSymbolicLink($link.LinkPath, $link.Target)
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            return "Could not link '$($link.LinkPath)' to '$($link.Target)': $($_.Exception.Message)"
        }
    }
    $null
}

function Test-SymlinkRights {
    # True when this process can create directory symlinks. On Windows that needs Developer Mode or an elevated shell.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not $IsWindows) {
        return $true
    }
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "sl-symlink-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path "$probe-target" -Force
    try {
        $null = [System.IO.Directory]::CreateSymbolicLink("$probe-link", "$probe-target")
        [System.IO.Directory]::Delete("$probe-link")
        $true
    }
    catch [System.IO.IOException], [System.UnauthorizedAccessException] {
        $false
    }
    finally {
        Remove-Item -LiteralPath "$probe-target" -Force -ErrorAction Ignore
    }
}

function Get-GitInfoExcludePath {
    # The info/exclude file of a checkout, or $null when the folder is not one. A worktree's .git is a file that points at
    # its own folder, whose commondir holds the shared info/exclude.
    param([Parameter(Mandatory, Position = 0)][string]$CheckoutPath)

    $dotGit = Join-Path $CheckoutPath '.git'
    $gitDirectory = $null
    if (Test-Path -LiteralPath $dotGit -PathType Container) {
        $gitDirectory = $dotGit
    }
    elseif (Test-Path -LiteralPath $dotGit -PathType Leaf) {
        $pointer = (Get-Content -LiteralPath $dotGit -TotalCount 1) -replace '^gitdir:\s*', ''
        if ($pointer) {
            $gitDirectory = [System.IO.Path]::GetFullPath($pointer, $CheckoutPath)
            $commonDirectoryFile = Join-Path $gitDirectory 'commondir'
            if (Test-Path -LiteralPath $commonDirectoryFile -PathType Leaf) {
                $gitDirectory = [System.IO.Path]::GetFullPath((Get-Content -LiteralPath $commonDirectoryFile -TotalCount 1).Trim(), $gitDirectory)
            }
        }
    }
    if (-not $gitDirectory) {
        return $null
    }
    Join-Path (Join-Path $gitDirectory 'info') 'exclude'
}

function Add-GitInfoExclude {
    # Adds the entry to the checkout's .git/info/exclude, so the file start writes does not dirty the checkout (H5).
    # True when it added the entry; false when the entry was there already or the folder is not a checkout.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$CheckoutPath,
        [Parameter(Mandatory, Position = 1)][string]$Entry
    )

    $excludePath = Get-GitInfoExcludePath -CheckoutPath $CheckoutPath
    if (-not $excludePath) {
        return $false
    }
    $text = if (Test-Path -LiteralPath $excludePath -PathType Leaf) { Get-Content -LiteralPath $excludePath -Raw } else { '' }
    if (@($text -split "`r?`n" | ForEach-Object { $_.Trim() }) -ccontains $Entry) {
        return $false
    }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $excludePath) -Force
    $separator = if ($text -and -not $text.EndsWith("`n")) { "`n" } else { '' }
    [System.IO.File]::AppendAllText($excludePath, "$separator$Entry`n", [System.Text.UTF8Encoding]::new($false))
    $true
}

function Get-SourcePlatformLogDir {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$SolutionFolder
    )

    Join-Path $SolutionFolder 'logs'
}

function Start-SourcePlatform {
    # Launches the platform in the background with ASPNETCORE_ENVIRONMENT=Development, in the command's working directory,
    # and records "<pid>;<start time ticks>" in <LogDir>/platform.pid. Returns the pid. The output goes to <LogDir>/platform.log.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Command,
        [Parameter(Mandatory, Position = 1)][string]$LogDir
    )

    $null = New-Item -ItemType Directory -Path $LogDir -Force
    $logPath = Join-Path $LogDir $script:SourcePlatformLogFileName
    $arguments = [string[]]@($Command.Arguments)

    if ($IsWindows) {
        # Start-Process hands the log files to the child as plain handles, so the log outlives this script. It needs a
        # file per stream, and quotes nothing by itself.
        $quoted = ($arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
        $previousEnvironment = $env:ASPNETCORE_ENVIRONMENT
        $env:ASPNETCORE_ENVIRONMENT = 'Development'
        try {
            $process = Start-Process -FilePath $Command.FilePath -ArgumentList $quoted -WorkingDirectory $Command.WorkingDirectory `
                -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError (Join-Path $LogDir 'platform.error.log') -PassThru
        }
        finally {
            $env:ASPNETCORE_ENVIRONMENT = $previousEnvironment
        }
    }
    else {
        # On Unix Start-Process copies the redirected output through this process, so the log would stop when the script
        # ends. The shell redirects the streams itself and execs the command, which keeps the command's pid and leaves it
        # no stdin and no handle of ours. It also takes the command out of this terminal's process group, so a Ctrl+C or a
        # closed terminal does not reach it: setsid where the host has it, else (macOS) INT, QUIT and HUP are ignored, and
        # an ignored signal stays ignored through exec, in the .NET host and in the processes it starts.
        $detach = 'if command -v setsid >/dev/null 2>&1; then set -- setsid "$@"; else trap "" INT QUIT HUP; fi'
        $info = [System.Diagnostics.ProcessStartInfo]::new('sh')
        foreach ($argument in @('-c', "log=`$1; shift; $detach; exec `"`$@`" >>`"`$log`" 2>&1 </dev/null", 'sh', $logPath, $Command.FilePath) + $arguments) {
            $info.ArgumentList.Add($argument)
        }
        $info.WorkingDirectory = $Command.WorkingDirectory
        $info.UseShellExecute = $false
        $info.Environment['ASPNETCORE_ENVIRONMENT'] = 'Development'
        $process = [System.Diagnostics.Process]::Start($info)
    }

    $pidText = "$($process.Id);$($process.StartTime.ToUniversalTime().Ticks)"
    [System.IO.File]::WriteAllText((Join-Path $LogDir $script:SourcePlatformPidFileName), $pidText, [System.Text.UTF8Encoding]::new($false))
    $process.Id
}

function Get-RunningSourcePlatform {
    # The process of the platform that <LogDir>/platform.pid records, or $null when the file is missing or malformed, the
    # process is gone, or it is not the recorded one (the pid was reused: its start time differs).
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LogDir
    )

    $pidPath = Join-Path $LogDir $script:SourcePlatformPidFileName
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
        return $null
    }
    $match = [regex]::Match((Get-Content -LiteralPath $pidPath -Raw).Trim(), '^(?<pid>\d+);(?<ticks>\d+)$')
    if (-not $match.Success) {
        return $null
    }
    $process = Get-Process -Id ([int]$match.Groups['pid'].Value) -ErrorAction Ignore
    if (-not $process) {
        return $null
    }
    try {
        $startTicks = $process.StartTime.ToUniversalTime().Ticks
    }
    catch [System.InvalidOperationException], [System.ComponentModel.Win32Exception] {
        # The process exited in between, or its start time is not readable (not ours).
        return $null
    }
    if ([Math]::Abs($startTicks - [long]$match.Groups['ticks'].Value) -gt $script:StartTimeToleranceTicks) {
        return $null
    }
    $process
}

function Stop-SourcePlatform {
    # Stops the platform that <LogDir>/platform.pid records, with every process it started (`dotnet run` runs the platform
    # as a child of the launcher). It kills nothing when the pid belongs to another process now. The pid file is always
    # removed. True when a process was stopped.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LogDir
    )

    $stopped = $false
    try {
        $process = Get-RunningSourcePlatform -LogDir $LogDir
        if ($process) {
            try {
                $process.Kill($true)
                $null = $process.WaitForExit(10000)
                $stopped = $true
            }
            catch [System.InvalidOperationException] {
                # It exited by itself in between.
                Write-Verbose "Stop-SourcePlatform: the platform process was gone already: $($_.Exception.Message)"
            }
        }
    }
    finally {
        Remove-Item -LiteralPath (Join-Path $LogDir $script:SourcePlatformPidFileName) -Force -ErrorAction Ignore
    }
    $stopped
}

function Get-ElasticsearchCaFingerprint {
    # The CA fingerprint that the Elasticsearch setup container writes to the certificates volume (E11): brings es-setup up
    # when needed, then copies ca/ca.fingerprint out of it. Run it in the solution folder. Throws when Compose fails.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Out-Host: whatever Compose prints must not become part of the returned fingerprint.
    Invoke-DockerCompose up -d --wait es-setup | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("docker compose up es-setup failed with exit code $LASTEXITCODE.")
    }
    $copyPath = Join-Path ([System.IO.Path]::GetTempPath()) "sl-ca-fingerprint-$([guid]::NewGuid().ToString('N'))"
    try {
        Invoke-DockerCompose cp es-setup:/usr/share/elasticsearch/config/certs/ca/ca.fingerprint $copyPath | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new("docker compose cp of ca.fingerprint failed with exit code $LASTEXITCODE.")
        }
        $fingerprint = (Get-Content -LiteralPath $copyPath -Raw).Trim()
    }
    finally {
        Remove-Item -LiteralPath $copyPath -Force -ErrorAction Ignore
    }
    if ($fingerprint -cnotmatch '^[0-9a-f]{64}$') {
        throw [System.InvalidOperationException]::new("ca.fingerprint of es-setup holds '$fingerprint', not a SHA-256 in hex.")
    }
    $fingerprint
}
