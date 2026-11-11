#Requires -Version 7.0
# Runs the Pester tests of one tier: pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit|Compose|All
param(
    [ValidateSet('Unit', 'Compose', 'All')][string]$Tier = 'Unit'
)

Import-Module Pester -MinimumVersion 5.0

$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
if ($Tier -ne 'All') {
    $configuration.Filter.Tag = $Tier
}

$result = Invoke-Pester -Configuration $configuration
exit ($result.FailedCount + $result.FailedBlocksCount + $result.FailedContainersCount)
