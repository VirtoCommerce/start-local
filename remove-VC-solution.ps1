# Guard: this script was renamed in start-local 2.0. It reads only .env, runs nothing else and loads no helpers,
# so it also works from Windows PowerShell 5.1 and with any arguments an old installer passed.
param(
    [Parameter(ValueFromRemainingArguments)]
    $remaining
)

$newName = 'remove.ps1'

$layout = 1
$envPath = Join-Path $PSScriptRoot '.env'
if (Test-Path -LiteralPath $envPath -PathType Leaf) {
    $match = [regex]::Match((Get-Content -LiteralPath $envPath -Raw), '(?m)^\s*START_LOCAL_LAYOUT\s*=\s*["'']?(\d+)')
    if ($match.Success) {
        $layout = [int]$match.Groups[1].Value
    }
}

if ($layout -ge 2) {
    Write-Host "$($MyInvocation.MyCommand.Name) was renamed to $newName. Run .\$newName instead; nothing was done." -ForegroundColor Yellow
    exit 1
}

Write-Host "$($MyInvocation.MyCommand.Name) belongs to the old start-local layout, which this version no longer supports. Nothing was done." -ForegroundColor Red
Write-Host '1. The old layout: download VirtoLocal_create_local_files.ps1 from the release/1.0 branch and run it, or pass -branch release/1.0 to your saved copy of the old installer.'
Write-Host '2. The new layout: run install.ps1. It migrates this folder to the new version and keeps its data.'
Write-Host '3. Warning: an old installer run over an existing folder has already regenerated the passwords in .env, so an existing database volume no longer accepts them. Restore the passwords from a backup of the old .env before you start the stack.'
exit 1
