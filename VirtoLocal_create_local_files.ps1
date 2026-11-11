# Renamed to install.ps1 (start-local 2.0); forwards to the latest release.
$installer = Join-Path $PSScriptRoot 'install.ps1'
Invoke-WebRequest https://github.com/VirtoCommerce/start-local/releases/latest/download/install.ps1 -OutFile $installer
& $installer @args
