# Helpers for the tests. Dot-source after scripts/_init.ps1: . "$PSScriptRoot/../support/TestHelpers.ps1"

function Get-TestRepositoryRoot {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
}

function Get-TestScratchRoot {
    # $TMPDIR on Linux and macOS, %TEMP% on Windows.
    [System.IO.Path]::GetTempPath()
}

function New-ComposeFixtureFolder {
    # A folder named $FolderName with the listed compose files from the repository and a .env made from
    # .env.example: COMPOSE_FILE set, secrets filled, then the overrides. Returns the folder path.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$ComposeFiles,
        [Parameter(Position = 1)][hashtable]$EnvOverrides = @{},
        [Parameter(Position = 2)][string]$FolderName = 'fixture'
    )

    $repositoryRoot = Get-TestRepositoryRoot
    $parent = Join-Path (Get-TestScratchRoot) "sl-fixture-$([guid]::NewGuid().ToString('N'))"
    $folder = Join-Path $parent $FolderName
    $null = New-Item -ItemType Directory -Path $folder -Force

    # A listed file the repository doesn't have yet is left out, so Compose reports it by name.
    foreach ($name in $ComposeFiles) {
        $source = Join-Path $repositoryRoot $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination $folder
        }
    }

    $document = Read-EnvFile (Join-Path $repositoryRoot '.env.example')
    $separator = Get-EnvValue -Document $document -Key 'COMPOSE_PATH_SEPARATOR' -Default ';'
    Set-EnvValue -Document $document -Key 'COMPOSE_FILE' -Value (ConvertTo-ComposeFileValue -ComposeFiles $ComposeFiles -Separator $separator)
    $null = Update-EnvSecrets -Document $document -SecretKeys $script:SecretKeys
    foreach ($key in $EnvOverrides.Keys) {
        Set-EnvValue -Document $document -Key $key -Value ([string]$EnvOverrides[$key])
    }
    Write-EnvFile -Document $document -Path (Join-Path $folder '.env')

    $folder
}

function Invoke-ComposeConfigJson {
    # `docker compose config --format json` in the folder, parsed. $env:SL_COMPOSE_BINARY, when set, is a
    # standalone Compose binary used instead of the `docker compose` plugin. Throws with Compose's message on failure.
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Folder
    )

    $arguments = @('config', '--format', 'json')
    Push-Location -LiteralPath $Folder
    try {
        $output = if ($env:SL_COMPOSE_BINARY) {
            & $env:SL_COMPOSE_BINARY @arguments 2>&1
        }
        else {
            & docker compose @arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $errorText = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw [System.InvalidOperationException]::new("docker compose config failed in '$Folder' (exit $exitCode): $errorText")
    }
    ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine | ConvertFrom-Json
}

function New-ScratchSolution {
    # A clean solution folder $TMPDIR/sl-<Name> holding the payload of this repository, for live checks.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][string]$Name = [guid]::NewGuid().ToString('N').Substring(0, 8)
    )

    $folder = Join-Path (Get-TestScratchRoot) "sl-$Name"
    if (Test-Path -LiteralPath $folder) {
        Remove-Item -LiteralPath $folder -Recurse -Force
    }
    Copy-Payload -Root (Get-TestRepositoryRoot) -Destination $folder
    $folder
}

function New-ModuleFolder {
    # A folder under TestDrive. With $ModuleId it holds a module.manifest, as a module's *.Web folder does.
    param([string]$Name, [string]$ModuleId)

    $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $path = Join-Path $folder $Name
    $null = New-Item -ItemType Directory -Path $path -Force
    if ($ModuleId) {
        Set-Content -LiteralPath (Join-Path $path 'module.manifest') -Value "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<module xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">`n  <id>$ModuleId</id>`n  <version>3.0.0</version>`n</module>"
    }
    $path
}
