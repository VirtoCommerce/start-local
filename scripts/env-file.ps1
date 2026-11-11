# The .env document model: parse a .env file into entries that keep every byte of
# the original (comments, blank lines, inline comments, line endings, BOM), so a
# value can change without the file being reformatted.
#
# Document: [pscustomobject]@{ Eol; Bom; Entries }
#   Eol     line terminator found in the file ("`n" or "`r`n")
#   Bom     $true when the file started with a UTF-8 BOM
#   Entries List of hashtables, one per line:
#     Kind='Pair'  Key, Value, Prefix (text before the value), Suffix (whitespace and
#                  inline comment after the value), Raw (the line as it is written)
#     Kind='Raw'   Raw only (comment, blank line, or a line this parser does not read)
#
# The parser follows the subset of compose-go that start-local relies on:
# KEY=VALUE, an optional "export ", '...', "...", and an unquoted value that, like in
# Docker Compose, ends at the first space followed by '#' (after leading whitespace is trimmed).
# Known limit: a quoted value spanning several lines is not understood; its lines are kept as they are.

$script:SecretKeys = 'DB_PASSWORD', 'REDIS_PASSWORD', 'ELASTIC_PASSWORD', 'KIBANA_PASSWORD'

$script:EnvKeyPattern = '[A-Za-z_][A-Za-z0-9_.-]*'
$script:EnvLinePattern = "^(?<head>\s*(?:export\s+)?(?<key>$($script:EnvKeyPattern))\s*=)(?<rest>.*)$"

function ConvertFrom-EnvLine {
    param([string]$Line)

    $rawEntry = @{ Kind = 'Raw'; Raw = $Line }
    $match = [regex]::Match($Line, $script:EnvLinePattern)
    if (-not $match.Success) {
        return $rawEntry
    }

    $prefix = $match.Groups['head'].Value
    $rest = $match.Groups['rest'].Value
    $leading = [regex]::Match($rest, '^\s*').Value
    $body = $rest.Substring($leading.Length)

    if ($body.Length -gt 0 -and ($body[0] -eq '"' -or $body[0] -eq "'")) {
        $quote = [string]$body[0]
        $closing = if ($quote -eq '"') {
            [regex]::Match($body.Substring(1), '^(?:[^"\\]|\\.)*"')
        }
        else {
            [regex]::Match($body.Substring(1), "^[^']*'")
        }
        if (-not $closing.Success) {
            return $rawEntry
        }
        $inner = $closing.Value.Substring(0, $closing.Value.Length - 1)
        if ($quote -eq '"') {
            $inner = [regex]::Replace($inner, '\\(.)', {
                    param($escape)
                    switch ($escape.Groups[1].Value) {
                        'n' { "`n" }
                        'r' { "`r" }
                        't' { "`t" }
                        default { $escape.Groups[1].Value }
                    }
                })
        }
        $value = $inner
        $suffix = $body.Substring(1 + $closing.Length)
        $prefix += $leading
    }
    else {
        # Mirrors Docker Compose 5.6.1: leading whitespace is trimmed, then the value ends at the first space
        # followed by '#' (a leading '#' is part of the value; a tab does not start a comment).
        $comment = [regex]::Match($body, ' +#')
        $valuePart = if ($comment.Success) { $body.Substring(0, $comment.Index) } else { $body }
        $commentPart = if ($comment.Success) { $body.Substring($comment.Index) } else { '' }
        $value = $valuePart.Trim()
        if ($value.Length -gt 0) {
            $prefix += $leading
            $suffix = [regex]::Match($valuePart, '\s*$').Value + $commentPart
        }
        else {
            $suffix = $leading
        }
    }

    return @{
        Kind   = 'Pair'
        Key    = $match.Groups['key'].Value
        Value  = $value
        Prefix = $prefix
        Suffix = $suffix
        Raw    = $Line
    }
}

function ConvertFrom-EnvText {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    # Ordinal on purpose: culture-aware StartsWith treats U+FEFF as ignorable and matches any text.
    $bom = $Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF
    if ($bom) {
        $Text = $Text.Substring(1)
    }

    $firstBreak = $Text.IndexOf("`n")
    $eol = if ($firstBreak -gt 0 -and $Text[$firstBreak - 1] -eq "`r") { "`r`n" } else { "`n" }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [regex]::Split($Text, "\r?\n")) {
        $entries.Add((ConvertFrom-EnvLine -Line $line))
    }

    return [pscustomobject]@{ Eol = $eol; Bom = $bom; Entries = $entries }
}

function ConvertTo-EnvText {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    $lines = foreach ($entry in $Document.Entries) { $entry.Raw }
    $text = $lines -join $Document.Eol
    if ($Document.Bom) {
        $text = [string][char]0xFEFF + $text
    }
    return $text
}

function Get-EnvTable {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][psobject]$Document)

    $table = [ordered]@{}
    foreach ($entry in $Document.Entries) {
        if ($entry.Kind -eq 'Pair') {
            $table[$entry.Key] = $entry.Value
        }
    }
    return $table
}

function Get-EnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$Key,
        [Parameter(Position = 2)][string]$Default
    )

    $table = Get-EnvTable -Document $Document
    if ($table.Contains($Key)) {
        return $table[$Key]
    }
    if ($PSBoundParameters.ContainsKey('Default')) {
        return $Default
    }
    return $null
}

function Assert-EnvValueWritable {
    param([string]$Key, [string]$Value)

    if ($Key -notmatch "^$($script:EnvKeyPattern)$") {
        throw [System.ArgumentException]::new("'$Key' is not a valid .env key.", 'Key')
    }
    $problem = if ($Value -match '[\r\n]') { 'a line break' }
    elseif ($Value.Contains('$')) { "'`$' (Compose would expand it)" }
    elseif ($Value.Contains('#')) { "'#' (it can start a comment)" }
    elseif ($Value.Contains('"') -or $Value.Contains("'")) { 'a quote' }
    elseif ($Value -ne $Value.Trim()) { 'leading or trailing whitespace' }
    if ($problem) {
        throw [System.ArgumentException]::new("The value for $Key contains $problem and cannot be stored in .env unchanged. Use a value without it.", 'Value')
    }
}

function Set-EnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$Key,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Value
    )

    Assert-EnvValueWritable -Key $Key -Value $Value

    # Compose uses the last occurrence of a duplicated key, so that is the one to change.
    $targetIndex = -1
    for ($index = 0; $index -lt $Document.Entries.Count; $index++) {
        $entry = $Document.Entries[$index]
        if ($entry.Kind -eq 'Pair' -and $entry.Key -eq $Key) {
            $targetIndex = $index
        }
    }

    if ($targetIndex -lt 0) {
        $newEntry = @{ Kind = 'Pair'; Key = $Key; Value = $Value; Prefix = "$Key="; Suffix = ''; Raw = "$Key=$Value" }
        # Keep the end-of-file newline: the empty last entry is what produces it.
        $last = $Document.Entries.Count - 1
        if ($last -ge 0 -and $Document.Entries[$last].Kind -eq 'Raw' -and $Document.Entries[$last].Raw -eq '') {
            $Document.Entries.Insert($last, $newEntry)
        }
        else {
            $Document.Entries.Add($newEntry)
        }
        return
    }

    # Compose reads "KEY=   # comment" as the value "# comment", so a rewritten line never keeps an inline
    # comment: the comment moves, verbatim, onto its own line above. Quotes are dropped: an accepted value never needs them.
    $target = $Document.Entries[$targetIndex]
    $comment = $target.Suffix.TrimStart()
    if ($comment.StartsWith('#')) {
        $Document.Entries.Insert($targetIndex, @{ Kind = 'Raw'; Raw = $comment.TrimEnd() })
    }
    $target.Value = $Value
    $target.Suffix = ''
    $target.Raw = $target.Prefix + $Value
}

function Remove-EnvKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )

    return $Document.Entries.RemoveAll([Predicate[object]] { param($entry) $entry.Kind -eq 'Pair' -and $entry.Key -eq $Key }) -gt 0
}

function Add-MissingEnvKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][psobject]$Template
    )

    $added = [System.Collections.Generic.List[string]]::new()
    $anchorKey = $null
    foreach ($templateEntry in $Template.Entries) {
        if ($templateEntry.Kind -ne 'Pair') {
            continue
        }
        $key = $templateEntry.Key
        $present = $false
        $anchorIndex = -1
        for ($index = 0; $index -lt $Document.Entries.Count; $index++) {
            $entry = $Document.Entries[$index]
            if ($entry.Kind -ne 'Pair') {
                continue
            }
            if ($entry.Key -eq $key) {
                $present = $true
            }
            if ($null -ne $anchorKey -and $entry.Key -eq $anchorKey) {
                $anchorIndex = $index
            }
        }
        if (-not $present) {
            # After the template's previous key (present by now: it was there or was just added); the first key goes on top.
            $Document.Entries.Insert($anchorIndex + 1, $templateEntry.Clone())
            $added.Add($key)
        }
        $anchorKey = $key
    }
    return , $added.ToArray()
}

function New-RandomPassword {
    [CmdletBinding()]
    param([int]$Length = 16)

    $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $characters = for ($position = 0; $position -lt $Length; $position++) {
        $alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)]
    }
    return -join $characters
}

function Update-EnvSecrets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string[]]$SecretKeys,
        [Parameter(Position = 2)][scriptblock]$Generator = { New-RandomPassword }
    )

    $filled = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $SecretKeys) {
        if ([string]::IsNullOrEmpty((Get-EnvValue -Document $Document -Key $key))) {
            Set-EnvValue -Document $Document -Key $key -Value ([string](& $Generator))
            $filled.Add($key)
        }
    }
    return , $filled.ToArray()
}

function Read-EnvFile {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    # .NET resolves paths against the process directory, not the PowerShell location, and ignores PSDrives.
    $bytes = [System.IO.File]::ReadAllBytes($PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path))
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes, $offset, $bytes.Length - $offset)
    if ($hasBom) {
        $text = [string][char]0xFEFF + $text
    }
    return ConvertFrom-EnvText -Text $text
}

function Write-EnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][psobject]$Document,
        [Parameter(Mandatory, Position = 1)][string]$Path
    )

    # The text carries the BOM character when the file was read with one; the encoder writes it as EF BB BF.
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-EnvText -Document $Document))
    [System.IO.File]::WriteAllBytes($PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path), $bytes)
}
