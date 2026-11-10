#Requires -Version 7.0
# Builds the platform and storefront Docker images for the solution folder's release channel.
# Configuration lives in .env; the parameters below are saved into it (SPEC §8).
param (
    [string]$solutionFolder = $PSScriptRoot,
    [string]$releaseChannel,
    [string]$customPackagesJson,
    [string]$customFrontendUrl,
    [Obsolete("Use -releaseChannel")]
    [string]$vcSolutionVersion,
    [bool]$skipSampleData = $false,
    [switch]$nonInteractive
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/scripts/_init.ps1"

function Assert-NativeSuccess {
    param([Parameter(Mandatory)][string]$Description)

    if ($LASTEXITCODE -ne 0) {
        throw [System.InvalidOperationException]::new("$Description failed with exit code $LASTEXITCODE.")
    }
}

function Install-CustomPackageManifest {
    # Copies or downloads the custom package manifest to $DestinationPath and checks it is usable.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if ($Source -match '^https?://') {
        Write-Host "Downloading custom package manifest from $Source..." -ForegroundColor Yellow
        try {
            Invoke-WebRequest -Uri $Source -OutFile $DestinationPath -ErrorAction Stop
        }
        catch {
            throw [System.InvalidOperationException]::new("failed to download custom package manifest from '$Source': $($_.Exception.Message)", $_.Exception)
        }
    }
    else {
        try {
            $resolvedSource = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path
        }
        catch {
            throw [System.IO.FileNotFoundException]::new("custom package manifest not found at '$Source'.", $Source)
        }
        Copy-Item -LiteralPath $resolvedSource -Destination $DestinationPath -Force
    }

    # Verify the manifest is well-formed JSON and has the required fields
    try {
        $manifest = Get-Content -Raw -LiteralPath $DestinationPath | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [System.FormatException]::new("custom package manifest at '$DestinationPath' is not valid JSON: $($_.Exception.Message)", $_.Exception)
    }
    if (-not $manifest.PlatformVersion) {
        throw [System.FormatException]::new("custom package manifest is missing required field 'PlatformVersion'.")
    }
    Write-Host "Custom manifest verified: PlatformVersion = $($manifest.PlatformVersion)" -ForegroundColor Green
    try {
        [void][System.Version]::Parse(($manifest.PlatformVersion -split '-', 2)[0])
    }
    catch {
        Write-Host "Warning: PlatformVersion '$($manifest.PlatformVersion)' may not be parseable by vc-build (System.Version expects numeric major.minor[.build[.revision]] before any prerelease suffix)." -ForegroundColor Yellow
    }
}

function Remove-FolderIfPresent {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

# The manifest path the user typed is relative to where they ran the script, not to the solution folder:
# resolve it before Push-Location so .env stores an absolute path. A relative value already in .env
# keeps resolving against the solution folder (Install-CustomPackageManifest runs after Push-Location).
$callerDirectory = (Get-Location).Path
if ($PSBoundParameters.ContainsKey('customPackagesJson')) {
    $PSBoundParameters['customPackagesJson'] = Resolve-ManifestSource ([string]$customPackagesJson) $callerDirectory
}

$solutionPath = (Resolve-Path -LiteralPath $solutionFolder -ErrorAction Stop).Path
Push-Location -LiteralPath $solutionPath
try {
    Invoke-StartLocalMigration $solutionPath | Out-Null

    $envPath = Join-Path $solutionPath '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        Write-Host "Error: $envPath not found. Run install.ps1 first." -ForegroundColor Red
        exit 1
    }
    $document = Read-EnvFile -Path $envPath

    $isNonInteractive = Test-NonInteractive -Switch $nonInteractive.IsPresent -InputRedirected ([Console]::IsInputRedirected) -CiValue ([string]$env:CI)

    foreach ($warning in (Update-EnvFromOptions -Document $document -Bound $PSBoundParameters)) {
        Write-Warning $warning
    }
    $manifestBeforePrompt = Get-EnvValue -Document $document -Key 'CUSTOM_PACKAGES_JSON'
    $missingKeys = Request-RequiredEnvKeys -Document $document -NonInteractive $isNonInteractive
    $manifestAfterPrompt = Get-EnvValue -Document $document -Key 'CUSTOM_PACKAGES_JSON'
    if ($manifestAfterPrompt -ne $manifestBeforePrompt) {
        # The interactive answer is relative to the caller's directory too.
        Set-EnvValue -Document $document -Key 'CUSTOM_PACKAGES_JSON' -Value (Resolve-ManifestSource $manifestAfterPrompt $callerDirectory)
    }
    Write-EnvFile -Document $document -Path $envPath
    if ($missingKeys.Count -gt 0) {
        Write-Host "Error: set $($missingKeys -join ', ') in $envPath, or pass the matching parameter." -ForegroundColor Red
        exit 1
    }

    $channel = ConvertTo-ReleaseChannel -Value (Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL')
    if (-not $channel) {
        Write-Host "Error: RELEASE_CHANNEL '$(Get-EnvValue -Document $document -Key 'RELEASE_CHANNEL')' is not a release channel. Use stable, stable:<N>, edge or custom." -ForegroundColor Red
        exit 1
    }
    $bundle = Get-BundleSpec -Channel $channel
    $features = Get-ComposeFeatures (Get-ComposeFileList (Get-EnvValue -Document $document -Key 'COMPOSE_FILE') (Get-EnvValue -Document $document -Key 'COMPOSE_PATH_SEPARATOR' -Default ';'))

    $stableJson = $null
    if ($channel.Kind -eq 'stable-n' -or ($features.Frontend -and $bundle.FrontendSource -eq 'bundle')) {
        $stableJson = Get-StableJson
    }
    if ($channel.Kind -eq 'stable-n' -and -not (Test-StableBundleKey $channel.Number $stableJson)) {
        Write-Host "Error: Stable $($channel.Number) is not listed in bundles/stable.json. Check RELEASE_CHANNEL." -ForegroundColor Red
        exit 1
    }

    $projectName = Get-EnvValue -Document $document -Key 'COMPOSE_PROJECT_NAME'
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        $projectName = Get-ComposeProjectName -FolderPath $solutionPath
    }

    if ($features.Platform) {
        $backendDir = Join-Path $solutionPath 'backend'
        $publishDir = Join-Path $backendDir 'publish'
        $customPackagesJsonPath = Join-Path $backendDir 'custom-packages.json'
        if (-not (Get-Command vc-build -CommandType Application, ExternalScript -ErrorAction Ignore)) {
            throw [System.InvalidOperationException]::new("'vc-build' is not on PATH. Install it with: dotnet tool install -g VirtoCommerce.GlobalTool")
        }
        if ($channel.Kind -eq 'custom') {
            Install-CustomPackageManifest -Source (Get-EnvValue -Document $document -Key 'CUSTOM_PACKAGES_JSON') -DestinationPath $customPackagesJsonPath
        }

        try {
            Write-Host "Building backend ($($channel.Normalized))..." -ForegroundColor Yellow
            $vcBuildArguments = Get-VcBuildInstallArgs $channel $customPackagesJsonPath (Join-Path $publishDir 'modules') (Join-Path $publishDir 'app_data/modules') $publishDir
            & vc-build @vcBuildArguments
            Assert-NativeSuccess 'vc-build install'
            Write-Host '... Backend built successfully' -ForegroundColor Green

            Write-Host 'Building backend Docker image...' -ForegroundColor Yellow
            docker build --no-cache -t "vc-platform:$projectName-latest" $backendDir
            Assert-NativeSuccess 'docker build of the platform image'
            Write-Host '... Backend Docker image built successfully' -ForegroundColor Green
        }
        finally {
            Remove-FolderIfPresent $publishDir
        }
    }

    if ($features.Frontend) {
        $frontendDir = Join-Path $solutionPath 'frontend'
        $frontendZipPath = Join-Path $frontendDir 'frontend.zip'
        $frontendArtifactDir = Join-Path $frontendDir 'artifact'

        $frontendZipUrl = switch ($bundle.FrontendSource) {
            'bundle' { Get-BundleFrontendUrl $bundle.BundleKey $stableJson }
            'latest-release' { Get-LatestFrontendReleaseUrl }
            'custom' {
                $customUrl = Get-EnvValue -Document $document -Key 'CUSTOM_FRONTEND_URL'
                # Only prompts on direct CLI invocation without the parameter, when .env has no URL yet.
                if ([string]::IsNullOrWhiteSpace($customUrl) -and -not $isNonInteractive -and -not $PSBoundParameters.ContainsKey('customFrontendUrl')) {
                    $customUrl = Read-Host 'Enter custom frontend ZIP URL (leave empty to use the latest vc-frontend GitHub release)'
                }
                if ([string]::IsNullOrWhiteSpace($customUrl)) { Get-LatestFrontendReleaseUrl } else { $customUrl.Trim() }
            }
        }

        try {
            Write-Host 'Downloading and extracting frontend files...' -ForegroundColor Yellow
            Remove-FolderIfPresent $frontendArtifactDir
            Invoke-WebRequest -Uri $frontendZipUrl -OutFile $frontendZipPath
            Expand-Archive -LiteralPath $frontendZipPath -DestinationPath $frontendArtifactDir
            Write-Host '... Frontend files downloaded and extracted' -ForegroundColor Green

            Write-Host 'Building frontend Docker image...' -ForegroundColor Yellow
            docker build -t "vc-frontend:$projectName-latest" $frontendDir
            Assert-NativeSuccess 'docker build of the storefront image'
            Write-Host '... Frontend Docker image built successfully' -ForegroundColor Green
        }
        finally {
            Remove-FolderIfPresent $frontendZipPath
            Remove-FolderIfPresent $frontendArtifactDir
        }
    }

    if (Read-YesNo -Prompt 'Start now?' -Default $true -NonInteractive $isNonInteractive) {
        $startScriptPath = Join-Path $solutionPath 'start.ps1'
        if (-not (Test-Path -LiteralPath $startScriptPath -PathType Leaf)) {
            Write-Host "Error: $startScriptPath not found, so the solution was not started." -ForegroundColor Red
            exit 1
        }
        Write-Host 'Starting run process...' -ForegroundColor Yellow
        $startArguments = @{ skipSampleData = $skipSampleData }
        if ($isNonInteractive) {
            $startArguments['nonInteractive'] = $true
        }
        & $startScriptPath @startArguments
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
    else {
        Write-Host 'Run process skipped. You can run it later with: ./start.ps1' -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    Pop-Location
}
