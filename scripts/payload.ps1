# The payload: the files a release delivers into a solution folder. install.ps1 copies them; .env is never one of them.

function Get-PayloadAllowlist {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    # Entries are paths relative to the payload root; a trailing '/' marks a folder, '*' a file name wildcard.
    , [string[]]@(
        'install.ps1', 'build.ps1', 'start.ps1', 'stop.ps1', 'remove.ps1',
        '.env.example', 'docker-compose*.yml',
        'scripts/', 'backend/', 'frontend/'
    )
}

function Copy-Payload {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][string]$Destination
    )

    $rootPath = (Resolve-Path -LiteralPath $Root).ProviderPath
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $destinationPath = (Resolve-Path -LiteralPath $Destination).ProviderPath

    $allowlist = Get-PayloadAllowlist
    foreach ($entry in $allowlist) {
        if ($entry.EndsWith('/')) {
            $folder = Join-Path $rootPath $entry.TrimEnd('/')
            if (Test-Path -LiteralPath $folder -PathType Container) {
                Copy-Item -LiteralPath $folder -Destination $destinationPath -Recurse -Force
            }
            continue
        }

        # -LiteralPath keeps '[' and ']' in the payload root literal; -Filter matches the entry by file name, in the root only.
        # No entry can match .env, which is the user's configuration: the payload never writes it.
        foreach ($file in Get-ChildItem -LiteralPath $rootPath -Filter $entry -File -Force) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destinationPath $file.Name) -Force
        }
    }
}
