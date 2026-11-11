#Requires -Version 7.0
# Installs or updates start-local in -targetFolder. Re-run it to update (SPEC §4.3).
# Two roles (SPEC §4.2): without -payloadPath it is the bootstrap, which downloads the release and delegates to the
# install.ps1 inside it; with -payloadPath it is the payload installer, whose logic is Invoke-PayloadInstall in scripts/payload.ps1.
param (
    [string]$targetFolder = 'VirtoLocal',
    [string]$branch,
    [ValidateSet('postgres', 'mysql', 'sqlserver')]
    [string]$dbProvider,
    [string]$releaseChannel,
    [string]$customPackagesJson,
    [string]$customFrontendUrl,
    [switch]$allowInsecureHttp,
    # --- Skip parts ---
    [switch]$skipPlatform,
    [switch]$skipFrontend,
    [switch]$skipElasticsearch,
    [switch]$skipKibana,
    [switch]$skipRedis,
    # --- Per run ---
    [bool]$skipSampleData = $false,
    [switch]$nonInteractive,
    # --- Obsolete ---
    [Obsolete("Use -releaseChannel")]
    [string]$vcSolutionVersion,
    [Obsolete("Set STACK_VERSION in .env")]
    [string]$elasticsearchVersion,
    [Parameter(DontShow)]
    [string]$payloadPath
)

$ErrorActionPreference = 'Stop'

if ($payloadPath) {
    . "$payloadPath/scripts/_init.ps1"

    try {
        $isNonInteractive = Test-NonInteractive -Switch $nonInteractive.IsPresent -InputRedirected ([Console]::IsInputRedirected) -CiValue ([string]$env:CI)
        $exitCode = Invoke-PayloadInstall -PayloadPath $payloadPath -TargetFolder $targetFolder -Bound $PSBoundParameters -NonInteractive $isNonInteractive
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit $exitCode
}

# The bootstrap role (resolve the release, download the payload, delegate) is added in the bootstrap task.
Write-Host 'Error: this installer cannot download a release yet. Pass -payloadPath <extracted payload folder>.' -ForegroundColor Red
exit 1
