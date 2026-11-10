# The development certificate of the HTTPS mode (SPEC §10): exported with `dotnet dev-certs`, delivered to the
# containers through the certificates volume (E10), never installed as trust by the scripts (E5).

$script:DevCertificateFileName = 'localhost.pem'

function Export-DevCertificate {
    # Exports the dotnet development certificate as <Destination>/localhost.pem + localhost.key (PEM, no password).
    # $false when dotnet is missing or the export fails.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Destination
    )

    if (-not (Get-Command dotnet -CommandType Application -ErrorAction Ignore)) {
        return $false
    }
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $exportPath = Join-Path $Destination $script:DevCertificateFileName
    $output = & dotnet dev-certs https --export-path $exportPath --format PEM --no-password 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "Export-DevCertificate: dotnet dev-certs failed with exit code ${LASTEXITCODE}: $output"
        return $false
    }
    (Test-Path -LiteralPath $exportPath -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Destination 'localhost.key') -PathType Leaf)
}

function Copy-DevCertificateToVolume {
    # Copies the files of SourceDir into dev/ of the named certificates volume, through a short-lived container.
    # A named volume needs no Docker Desktop File Sharing, unlike a bind mount (E10). Throws when Docker fails.
    # The volume is created first, when missing, with the ownership labels Compose puts on its own volumes (R29):
    # otherwise Compose warns "was not created by Docker Compose" on every start and `down -v` skips the volume.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$VolumeName,
        [Parameter(Mandatory, Position = 1)][string]$SourceDir,
        [Parameter(Mandatory, Position = 2)][string]$ProjectName
    )

    $null = & docker volume create --label "com.docker.compose.project=$ProjectName" --label 'com.docker.compose.volume=certs' $VolumeName
    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("docker volume create for the volume '$VolumeName' failed with exit code $LASTEXITCODE.")
    }

    # Capture first, check the exit code, then take the first line: `| Select-Object -First 1` stops the pipeline
    # before PowerShell updates $LASTEXITCODE, so the check would read the previous native command's code.
    $createOutput = & docker container create -v "${VolumeName}:/certs" alpine
    $createExitCode = $LASTEXITCODE
    $containerId = ($createOutput | Select-Object -First 1)
    if ($createExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
        throw [System.InvalidOperationException]::new("docker container create for the volume '$VolumeName' failed with exit code $createExitCode.")
    }
    try {
        $sourcePath = (Resolve-Path -LiteralPath $SourceDir).ProviderPath
        & docker cp "$sourcePath/." "${containerId}:/certs/dev/"
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new("docker cp of '$SourceDir' into the volume '$VolumeName' failed with exit code $LASTEXITCODE.")
        }
    }
    finally {
        $null = & docker rm $containerId
    }
}

function Sync-DevCertificate {
    # Puts the development certificate in the certificates volume. Exports it into <SolutionFolder>/backend/certs
    # first when the export is missing, so a folder built in HTTP mode can switch to HTTPS without a rebuild.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$SolutionFolder,
        [Parameter(Mandatory, Position = 1)][string]$VolumeName,
        [Parameter(Mandatory, Position = 2)][string]$ProjectName
    )

    $certsDirectory = Join-Path (Join-Path $SolutionFolder 'backend') 'certs'
    if (-not (Test-Path -LiteralPath (Join-Path $certsDirectory $script:DevCertificateFileName) -PathType Leaf)) {
        if (-not (Export-DevCertificate -Destination $certsDirectory)) {
            throw [System.InvalidOperationException]::new("The development certificate could not be exported into '$certsDirectory'. Install the .NET SDK, then run: dotnet dev-certs https --export-path '$(Join-Path $certsDirectory $script:DevCertificateFileName)' --format PEM --no-password")
        }
    }
    Copy-DevCertificateToVolume -VolumeName $VolumeName -SourceDir $certsDirectory -ProjectName $ProjectName
}

function Test-DevCertificateTrusted {
    # True when `dotnet dev-certs https --check --trust` finds the certificate trusted. Trust added to the system
    # store by hand is not detected (FC §11), so the instructions offer both routes.
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Get-Command dotnet -CommandType Application -ErrorAction Ignore)) {
        return $false
    }
    $null = & dotnet dev-certs https --check --trust 2>&1
    $LASTEXITCODE -eq 0
}

function Get-TrustInstructions {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @(
        'Browsers and tools warn about the development certificate until it is trusted. The scripts never install trust; pick a route:'
        '  1. dotnet dev-certs https --trust'
        '     Windows and macOS. Ubuntu and Fedora with .NET 9 or later, after: export SSL_CERT_DIR="$HOME/.aspnet/dev-certs/trust:/usr/lib/ssl/certs"'
        '  2. Linux system store:'
        '     sudo cp backend/certs/localhost.pem /usr/local/share/ca-certificates/start-local-dev.crt'
        '     sudo update-ca-certificates'
    ) -join [Environment]::NewLine
}

function Get-CertsVolumeName {
    # The certificates volume of a solution folder, named as docker-compose.https.yml names it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$SolutionFolder
    )

    "$(Get-VolumePrefix -Document $Document -SolutionFolder $SolutionFolder)_certs"
}
