BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    $script:FixtureFolder = Join-Path $PSScriptRoot '../fixtures/env'
    $script:ExampleText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.env.example') -Raw
}

Describe 'EnvFile' -Tag 'Unit' {
    It 'round-trips .env.example byte for byte' {
        ConvertTo-EnvText (ConvertFrom-EnvText $script:ExampleText) | Should -BeExactly $script:ExampleText
    }

    It 'round-trips CRLF and keeps the BOM (<Name>)' -TestCases @(
        @{ Name = 'layout1-edited-crlf.env' }
        @{ Name = 'bom.env' }
    ) {
        $source = Join-Path $script:FixtureFolder $Name
        $copy = Join-Path $TestDrive $Name
        Write-EnvFile -Document (Read-EnvFile -Path $source) -Path $copy
        [System.IO.File]::ReadAllBytes($copy) | Should -Be ([System.IO.File]::ReadAllBytes($source))
    }

    It 'reads and writes through a PSDrive path and a path relative to the current location' {
        Set-Content -LiteralPath (Join-Path $TestDrive 'a.env') -Value "A=1`n"
        (Get-EnvValue (Read-EnvFile -Path 'TestDrive:/a.env') 'A') | Should -BeExactly '1'
        Push-Location $TestDrive
        try {
            $document = Read-EnvFile -Path 'a.env'
            Set-EnvValue $document 'A' '2'
            Write-EnvFile -Document $document -Path 'b.env'
        }
        finally {
            Pop-Location
        }
        (Get-EnvValue (Read-EnvFile -Path (Join-Path $TestDrive 'b.env')) 'A') | Should -BeExactly '2'
    }

    It 'reads the BOM and CRLF into the document' {
        $document = Read-EnvFile -Path (Join-Path $script:FixtureFolder 'bom.env')
        $document.Bom | Should -BeTrue
        $document.Eol | Should -BeExactly "`r`n"
        (Get-EnvValue $document 'COMPOSE_PROJECT_NAME') | Should -BeExactly 'virto'
        (Get-EnvValue $document 'BIND_ADDRESS') | Should -BeExactly '127.0.0.1'
        (Get-EnvValue $document 'PLATFORM_PORT') | Should -BeExactly '8090'
    }

    It 'strips inline comments from unquoted values' {
        $document = ConvertFrom-EnvText "COMPOSE_PATH_SEPARATOR=;`n# note`nBIND_ADDRESS=127.0.0.1 # loopback`nCOMPOSE_FILE=`n"
        $table = Get-EnvTable $document
        $table['COMPOSE_PATH_SEPARATOR'] | Should -BeExactly ';'
        $table['BIND_ADDRESS'] | Should -BeExactly '127.0.0.1'
        $table['COMPOSE_FILE'] | Should -BeExactly ''
        $table = Get-EnvTable (ConvertFrom-EnvText $script:ExampleText)
        $table['COMPOSE_PATH_SEPARATOR'] | Should -BeExactly ';'
        $table['COMPOSE_FILE'] | Should -BeExactly ''
    }

    # Docker Compose 5.6.1 values (docker compose config), so the scripts and Compose read the same .env.
    It 'reads unquoted values like Docker Compose: <Line>' -TestCases @(
        @{ Line = 'A=   # c1'; Expected = '# c1' }
        @{ Line = 'B=val # c2'; Expected = 'val' }
        @{ Line = 'C=val# c3'; Expected = 'val# c3' }
        @{ Line = 'D=#c4'; Expected = '#c4' }
        @{ Line = 'E="q v" # c5'; Expected = 'q v' }
        @{ Line = 'F='; Expected = '' }
        @{ Line = 'G=  spaced  '; Expected = 'spaced' }
        @{ Line = "H=val`t# tab"; Expected = "val`t# tab" }
        @{ Line = 'I=   #x #y'; Expected = '#x' }
        @{ Line = 'J=# a # b'; Expected = '# a' }
        @{ Line = 'K=#a #b #c'; Expected = '#a' }
        @{ Line = 'L=val # a # b'; Expected = 'val' }
        @{ Line = "M=val`t #c"; Expected = 'val' }
        @{ Line = "N=#a`t#b"; Expected = "#a`t#b" }
    ) {
        $document = ConvertFrom-EnvText "$Line`n"
        (Get-EnvTable $document).Values | Select-Object -First 1 | Should -BeExactly $Expected
        ConvertTo-EnvText $document | Should -BeExactly "$Line`n"
    }

    It 'reads quoted values and the export prefix' {
        $document = ConvertFrom-EnvText "export A='x # y' # c`nB=`"p q`"`nC=  spaced  `n"
        (Get-EnvValue $document 'A') | Should -BeExactly 'x # y'
        (Get-EnvValue $document 'B') | Should -BeExactly 'p q'
        (Get-EnvValue $document 'C') | Should -BeExactly 'spaced'
        ConvertTo-EnvText $document | Should -BeExactly "export A='x # y' # c`nB=`"p q`"`nC=  spaced  `n"
    }

    It 'returns the default only for an absent key' {
        $document = ConvertFrom-EnvText "A=`n"
        (Get-EnvValue $document 'A' 'fallback') | Should -BeExactly ''
        (Get-EnvValue $document 'B' 'fallback') | Should -BeExactly 'fallback'
        (Get-EnvValue $document 'B') | Should -BeNullOrEmpty
    }

    It 'Set-EnvValue moves an inline comment onto its own line above the key' {
        $document = ConvertFrom-EnvText "A=1`nB=old   # why it is here`nC=3`n"
        Set-EnvValue $document 'B' 'new'
        ConvertTo-EnvText $document | Should -BeExactly "A=1`n# why it is here`nB=new`nC=3`n"
        (Get-EnvValue $document 'B') | Should -BeExactly 'new'
    }

    It 'Set-EnvValue moves the comment of an empty quoted value too' {
        $document = ConvertFrom-EnvText "B=`"`" # why`n"
        Set-EnvValue $document 'B' 'x'
        ConvertTo-EnvText $document | Should -BeExactly "# why`nB=x`n"
    }

    It 'Set-EnvValue on a quoted value rewrites it unquoted and moves the comment' {
        $document = ConvertFrom-EnvText "A='old' # note`n"
        Set-EnvValue $document 'A' 'new'
        ConvertTo-EnvText $document | Should -BeExactly "# note`nA=new`n"
    }

    It 'Set-EnvValue leaves every other line byte for byte' {
        $document = ConvertFrom-EnvText $script:ExampleText
        Set-EnvValue $document 'BIND_ADDRESS' '0.0.0.0'
        $expected = $script:ExampleText -replace '(?m)^BIND_ADDRESS=127\.0\.0\.1$', 'BIND_ADDRESS=0.0.0.0'
        $expected | Should -Not -BeExactly $script:ExampleText
        ConvertTo-EnvText $document | Should -BeExactly $expected
    }

    It '.env.example has no inline comments (Compose reads "KEY=   # c" as the value "# c")' {
        ($script:ExampleText -split "`n") | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*=.*\s#' } | Should -BeNullOrEmpty
    }

    It 'Set-EnvValue appends a missing key as the last line' {
        $document = Read-EnvFile -Path (Join-Path $script:FixtureFolder 'layout1-postgres.env')
        Set-EnvValue $document 'NEW_KEY' 'v1'
        $text = ConvertTo-EnvText $document
        $text | Should -BeExactly ((Get-Content -LiteralPath (Join-Path $script:FixtureFolder 'layout1-postgres.env') -Raw) + "NEW_KEY=v1`n")
    }

    It 'Set-EnvValue appends to a file without a final newline' {
        $document = ConvertFrom-EnvText 'A=1'
        Set-EnvValue $document 'B' '2'
        ConvertTo-EnvText $document | Should -BeExactly "A=1`nB=2"
    }

    It 'Set-EnvValue rejects values it cannot round-trip (<Label>)' -TestCases @(
        @{ Label = 'dollar'; Value = 'a$b' }
        @{ Label = 'hash'; Value = 'a #b' }
        @{ Label = 'double quote'; Value = '"q"' }
        @{ Label = 'single quote'; Value = "a'b" }
        @{ Label = 'newline'; Value = "a`nb" }
    ) {
        $document = ConvertFrom-EnvText "DB_PASSWORD=old`n"
        { Set-EnvValue $document 'DB_PASSWORD' $Value } |
            Should -Throw -ExceptionType ([System.ArgumentException]) -ExpectedMessage '*DB_PASSWORD*'
        (Get-EnvValue $document 'DB_PASSWORD') | Should -BeExactly 'old'
    }

    It 'Remove-EnvKey removes every occurrence and reports whether it did' {
        $document = ConvertFrom-EnvText "A=1`nB=2`nA=3`n"
        Remove-EnvKey $document 'A' | Should -BeTrue
        Remove-EnvKey $document 'A' | Should -BeFalse
        ConvertTo-EnvText $document | Should -BeExactly "B=2`n"
    }

    It 'Add-MissingEnvKeys adds only absent keys after their template neighbour' {
        $document = Read-EnvFile -Path (Join-Path $script:FixtureFolder 'layout1-postgres.env')
        $template = ConvertFrom-EnvText $script:ExampleText
        $added = Add-MissingEnvKeys $document $template
        $added | Should -Contain 'START_LOCAL_LAYOUT'
        $added | Should -Contain 'BIND_ADDRESS'
        $added | Should -Not -Contain 'DB_PASSWORD'
        (Get-EnvValue $document 'DB_PASSWORD') | Should -BeExactly 'pgPass1'
        (Get-EnvValue $document 'PLATFORM_PORT') | Should -BeExactly '8090'
        $keys = @((Get-EnvTable $document).Keys)
        $keys.IndexOf('SEARCH_PROVIDER') | Should -Be ($keys.IndexOf('CUSTOM_FRONTEND_URL') + 1)
        $keys.IndexOf('BIND_ADDRESS') | Should -Be ($keys.IndexOf('VOLUME_PREFIX') + 1)
        (Add-MissingEnvKeys $document $template) | Should -BeNullOrEmpty
        $addedLines = (ConvertTo-EnvText $document) -split "`r?`n" | Where-Object { $_ -match '^([A-Za-z_][A-Za-z0-9_]*)=' -and $added -contains $Matches[1] }
        $addedLines | Should -HaveCount $added.Count
        ($addedLines | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*=\s*#' }) | Should -BeNullOrEmpty
    }

    It 'Update-EnvSecrets fills empty secrets and never rotates' {
        $document = ConvertFrom-EnvText $script:ExampleText
        $script:Counter = 0
        $generator = { 'secret' + (++$script:Counter) }
        $first = Update-EnvSecrets $document $script:SecretKeys $generator
        $first | Should -HaveCount 4
        $before = ConvertTo-EnvText $document
        $second = Update-EnvSecrets $document $script:SecretKeys $generator
        $second | Should -HaveCount 0
        ConvertTo-EnvText $document | Should -BeExactly $before
        (Get-EnvValue $document 'DB_PASSWORD') | Should -BeExactly 'secret1'
    }

    It 'Update-EnvSecrets adds a secret key the file lacks' {
        $document = ConvertFrom-EnvText "DB_PASSWORD=keep`n"
        Update-EnvSecrets $document @('DB_PASSWORD', 'REDIS_PASSWORD') { 'gen' } | Should -Be @('REDIS_PASSWORD')
        (Get-EnvValue $document 'DB_PASSWORD') | Should -BeExactly 'keep'
        (Get-EnvValue $document 'REDIS_PASSWORD') | Should -BeExactly 'gen'
    }

    It 'New-RandomPassword returns 16 alphanumerics' {
        New-RandomPassword | Should -Match '^[A-Za-z0-9]{16}$'
    }
}
