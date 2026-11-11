BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'HTTPS certificates' -Tag 'Unit' {
    It 'trust instructions name both routes' {
        $text = Get-TrustInstructions
        $text | Should -BeLike '*dotnet dev-certs https --trust*'
        $text | Should -BeLike '*SSL_CERT_DIR*'
        $text | Should -BeLike '*/usr/local/share/ca-certificates*'
        $text | Should -BeLike '*update-ca-certificates*'
    }

    Context 'Sync-DevCertificate' {
        BeforeEach {
            $solution = Join-Path 'TestDrive:' "solution-$([guid]::NewGuid().ToString('N'))"
            $certsDirectory = Join-Path (Join-Path $solution 'backend') 'certs'
            $null = New-Item -ItemType Directory -Path $solution -Force
            Mock Export-DevCertificate { $true }
            Mock Copy-DevCertificateToVolume { }
        }

        It 'exports only when the export is missing, and always copies' -ForEach @(
            @{ Label = 'no localhost.pem'; Present = $false; Exports = 1 }
            @{ Label = 'localhost.pem present'; Present = $true; Exports = 0 }
        ) {
            if ($Present) {
                $null = New-Item -ItemType File -Path (Join-Path $certsDirectory 'localhost.pem') -Force
            }

            Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl'

            Should -Invoke Export-DevCertificate -Times $Exports -Exactly -ParameterFilter {
                ($Destination -replace '\\', '/') -like '*/backend/certs'
            }
            Should -Invoke Export-DevCertificate -Times $Exports -Exactly
            Should -Invoke Copy-DevCertificateToVolume -Times 1 -Exactly -ParameterFilter {
                $VolumeName -eq 'sl_certs' -and $ProjectName -eq 'sl' -and ($SourceDir -replace '\\', '/') -like '*/backend/certs'
            }
        }

        It 'throws and copies nothing when the export fails' {
            Mock Export-DevCertificate { $false }

            { Sync-DevCertificate -SolutionFolder $solution -VolumeName 'sl_certs' -ProjectName 'sl' } | Should -Throw '*could not be exported*'

            Should -Invoke Copy-DevCertificateToVolume -Times 0 -Exactly
        }
    }

    Context 'Copy-DevCertificateToVolume' {
        BeforeAll {
            # Pester mocks a command that exists; the shim stands in for the docker CLI.
            function script:docker { }
        }

        BeforeEach {
            $source = Join-Path 'TestDrive:' "certs-$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType File -Path (Join-Path $source 'localhost.pem') -Force
            $script:dockerCalls = [System.Collections.Generic.List[string]]::new()
            $script:failingVerb = $null
            Mock docker {
                $script:dockerCalls.Add($args -join ' ')
                $global:LASTEXITCODE = if ($args[0] -eq $script:failingVerb) { 1 } else { 0 }
                if ($args[0] -eq 'container') { 'abc123' }
            }
        }

        It 'creates the volume with the Compose ownership labels, then a container on it, copies into dev/ and removes the container' {
            Copy-DevCertificateToVolume -VolumeName 'sl_certs' -SourceDir $source -ProjectName 'sl'

            $script:dockerCalls.Count | Should -Be 4
            $script:dockerCalls[0] | Should -Be 'volume create --label com.docker.compose.project=sl --label com.docker.compose.volume=certs sl_certs'
            $script:dockerCalls[1] | Should -Be 'container create -v sl_certs:/certs alpine'
            $script:dockerCalls[2] | Should -BeLike 'cp *abc123:/certs/dev/'
            ($script:dockerCalls[2] -replace '\\', '/') | Should -BeLike 'cp */certs-*/. abc123:/certs/dev/'
            $script:dockerCalls[3] | Should -Be 'rm abc123'
        }

        It 'removes the container and throws when the copy fails' {
            $script:failingVerb = 'cp'

            { Copy-DevCertificateToVolume -VolumeName 'sl_certs' -SourceDir $source -ProjectName 'sl' } | Should -Throw '*docker cp*failed*'

            $script:dockerCalls[-1] | Should -Be 'rm abc123'
        }

        It 'throws and runs nothing else when the volume cannot be created' {
            $script:failingVerb = 'volume'

            { Copy-DevCertificateToVolume -VolumeName 'sl_certs' -SourceDir $source -ProjectName 'sl' } | Should -Throw '*docker volume create*failed*'

            $script:dockerCalls.Count | Should -Be 1
        }
    }

    It 'Get-CertsVolumeName is the volume prefix plus _certs' {
        $path = Join-Path 'TestDrive:' "env-$([guid]::NewGuid().ToString('N'))"
        Set-Content -LiteralPath $path -Value @('VOLUME_PREFIX=virto', 'COMPOSE_PROJECT_NAME=other')

        Get-CertsVolumeName -Document (Read-EnvFile -Path $path) -SolutionFolder (Join-Path 'TestDrive:' 'My-Stack') | Should -Be 'virto_certs'
    }
}
