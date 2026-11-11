# Release channels: parsing RELEASE_CHANNEL and turning it into vc-build arguments and a bundle spec.
#
# Channel: [pscustomobject]@{ Kind; Number; Normalized; Warnings }
#   Kind        stable | stable-n | edge | custom
#   Number      the N of 'stable:<N>'; else $null
#   Normalized  the canonical value to write back to .env ('stable', 'stable:16', 'edge', 'custom')
#   Warnings    string[] of notes for the user (for example the rename of 'latest-stable')
#
# The channel names follow Virto Commerce's release channels and vc-build's switches: stable is the absence
# of -Edge, '-v <N>' picks Stable N. The numbers have gaps, and vc-build crashes on an unknown key, so
# '<N>' is checked against the keys of bundles/stable.json first.

$script:StableJsonUrl = 'https://raw.githubusercontent.com/VirtoCommerce/vc-modules/refs/heads/master/bundles/stable.json'
$script:LatestFrontendReleaseApiUrl = 'https://api.github.com/repos/VirtoCommerce/vc-frontend/releases/latest'

function ConvertTo-ReleaseChannel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Value
    )

    $text = if ($null -eq $Value) { '' } else { $Value.Trim().ToLowerInvariant() }
    $warnings = [string[]]@()
    $kind = $null
    $number = $null

    $stableNumber = [regex]::Match($text, '^stable:(?<number>\d+)$')
    switch -Regex ($text) {
        '^stable$' { $kind = 'stable' }
        '^latest-stable$' {
            $kind = 'stable'
            $warnings = [string[]]@("Release channel 'latest-stable' was renamed to 'stable'; using 'stable'.")
        }
        '^edge$' { $kind = 'edge' }
        '^custom$' { $kind = 'custom' }
        default {
            $parsed = 0
            if ($stableNumber.Success -and [int]::TryParse($stableNumber.Groups['number'].Value, [ref]$parsed)) {
                $kind = 'stable-n'
                $number = $parsed
            }
        }
    }
    if (-not $kind) {
        return $null
    }

    [pscustomobject]@{
        Kind       = $kind
        Number     = $number
        Normalized = if ($kind -eq 'stable-n') { "stable:$number" } else { $kind }
        Warnings   = $warnings
    }
}

function Test-StableBundleKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][int]$Number,
        [Parameter(Mandatory, Position = 1)][psobject]$StableJson
    )

    # The lookup in vc-build is an exact match on the key: '16' works, 'v16' does not.
    $StableJson.PSObject.Properties.Name -ccontains "$Number"
}

function Get-BundleSpec {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Channel
    )

    switch ($Channel.Kind) {
        'stable' { $bundleKey = 'latest'; $edge = $false; $frontendSource = 'bundle' }
        'stable-n' { $bundleKey = "$($Channel.Number)"; $edge = $false; $frontendSource = 'bundle' }
        'edge' { $bundleKey = $null; $edge = $true; $frontendSource = 'latest-release' }
        'custom' { $bundleKey = $null; $edge = $false; $frontendSource = 'custom' }
        default { throw [System.ArgumentException]::new("Unknown release channel kind '$($Channel.Kind)'.", 'Channel') }
    }

    [pscustomobject]@{
        BundleKey      = $bundleKey
        Edge           = $edge
        FrontendSource = $frontendSource
    }
}

function Get-VcBuildInstallArgs {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Channel,
        [Parameter(Mandatory, Position = 1)][string]$ManifestPath,
        [Parameter(Mandatory, Position = 2)][string]$DiscoveryPath,
        [Parameter(Mandatory, Position = 3)][string]$ProbingPath,
        [Parameter(Mandatory, Position = 4)][string]$Root
    )

    # @() keeps a one-item result an array, so the '+' below appends instead of concatenating strings.
    $head = @(switch ($Channel.Kind) {
        'stable' { @('install') }
        'stable-n' { @('install', '-v', "$($Channel.Number)") }
        'edge' { @('install', '-Edge') }
        'custom' { @('install', '--package-manifest-path', $ManifestPath) }
        default { throw [System.ArgumentException]::new("Unknown release channel kind '$($Channel.Kind)'.", 'Channel') }
    })
    $tail = '--probing-path', $ProbingPath, '--discovery-path', $DiscoveryPath, '--root', $Root, '--skip-dependency-solving'

    # The unary comma keeps the array intact through the pipeline.
    , [string[]]@($head + $tail)
}

function ConvertFrom-JsonResponse {
    param($Response)

    # raw.githubusercontent.com serves text/plain, so Invoke-RestMethod may hand back the raw text.
    if ($Response -is [string]) {
        return $Response | ConvertFrom-Json
    }
    $Response
}

function Get-StableJson {
    [CmdletBinding()]
    [OutputType([psobject])]
    param()

    ConvertFrom-JsonResponse (Invoke-RestMethod -Uri $script:StableJsonUrl)
}

function Get-BundleFrontendUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$BundleKey,
        [Parameter(Mandatory, Position = 1)][psobject]$StableJson
    )

    $property = $StableJson.PSObject.Properties[$BundleKey]
    if (-not $property) {
        throw [System.ArgumentException]::new("Bundle '$BundleKey' is not listed in bundles/stable.json.", 'BundleKey')
    }

    $packages = ConvertFrom-JsonResponse (Invoke-RestMethod -Uri $property.Value)
    $frontendUrl = $packages.ThemeB2BVue
    if ([string]::IsNullOrWhiteSpace($frontendUrl)) {
        throw [System.InvalidOperationException]::new("Bundle '$BundleKey' has no ThemeB2BVue entry in its package.json.")
    }
    $frontendUrl
}

function Get-LatestFrontendReleaseUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $release = Invoke-RestMethod -Uri $script:LatestFrontendReleaseApiUrl
    $asset = @($release.assets | Where-Object { $_.name -like '*.zip' }) | Select-Object -First 1
    if (-not $asset) {
        throw [System.InvalidOperationException]::new('The latest vc-frontend release has no .zip asset.')
    }
    $asset.browser_download_url
}
