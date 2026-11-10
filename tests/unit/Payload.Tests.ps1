BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
}

Describe 'Payload' -Tag 'Unit' {
    It 'allowlist excludes docs, tests, .github and the four old-named scripts' {
        $allowlist = Get-PayloadAllowlist
        $allowlist | Should -Not -Contain 'docs/'
        $allowlist | Should -Not -Contain 'tests/'
        $allowlist | Should -Not -Contain '.github/'
        $oldNames = 'VirtoLocal_create_local_files.ps1', 'build-VC-solution.ps1', 'start-VC-solution.ps1', 'stop-VC-solution.ps1', 'remove-VC-solution.ps1'
        foreach ($oldName in $oldNames) {
            $allowlist | Should -Not -Contain $oldName
        }
        $allowlist | Should -Contain 'install.ps1'
        $allowlist | Should -Contain '.env.example'
        $allowlist | Should -Contain 'docker-compose*.yml'
    }

    Context 'Copy-Payload' {
        BeforeEach {
            $root = Join-Path 'TestDrive:' "source-$([guid]::NewGuid().ToString('N'))"
            foreach ($relative in 'install.ps1', 'start.ps1', '.env.example', 'docker-compose.yml', 'docker-compose.redis.yml',
                'scripts/_init.ps1', 'frontend/Dockerfile', 'docs/readme.md', 'tests/a.Tests.ps1', '.github/ci.yml',
                'build-VC-solution.ps1', 'VirtoLocal_create_local_files.ps1', 'notes.txt') {
                $null = New-Item -ItemType File -Path (Join-Path $root $relative) -Force -Value "root $relative"
            }
            Set-Content -LiteralPath (Join-Path $root '.env') -Value 'SOURCE_SECRET=1'
            $destination = Join-Path 'TestDrive:' "solution-$([guid]::NewGuid().ToString('N'))"
        }

        It 'copies the allowlisted files and folders only' {
            Copy-Payload -Root $root -Destination $destination

            foreach ($relative in 'install.ps1', 'start.ps1', '.env.example', 'docker-compose.yml', 'docker-compose.redis.yml', 'scripts/_init.ps1', 'frontend/Dockerfile') {
                Join-Path $destination $relative | Should -Exist
            }
            foreach ($relative in 'docs', 'tests', '.github', 'build-VC-solution.ps1', 'VirtoLocal_create_local_files.ps1', 'notes.txt') {
                Join-Path $destination $relative | Should -Not -Exist
            }
        }

        It 'copies root-level files when the payload root contains wildcard characters' {
            $bracketRoot = Join-Path 'TestDrive:' "source [x]-$([guid]::NewGuid().ToString('N'))"
            foreach ($relative in 'install.ps1', '.env.example', 'docker-compose.yml', 'scripts/_init.ps1') {
                $null = New-Item -ItemType File -Path (Join-Path $bracketRoot $relative) -Force -Value "root $relative"
            }

            Copy-Payload -Root $bracketRoot -Destination $destination

            foreach ($relative in 'install.ps1', '.env.example', 'docker-compose.yml', 'scripts/_init.ps1') {
                Join-Path $destination $relative | Should -Exist
            }
        }

        It 'skips allowlisted files that do not exist yet' {
            { Copy-Payload -Root $root -Destination $destination } | Should -Not -Throw
            Join-Path $destination 'build.ps1' | Should -Not -Exist
            Join-Path $destination 'backend' | Should -Not -Exist
        }

        It 'never touches an existing .env' {
            $null = New-Item -ItemType Directory -Path $destination
            $envPath = Join-Path (Resolve-Path -LiteralPath $destination).ProviderPath '.env'
            $sentinel = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("DB_PASSWORD=keep`r`n# user edit`r`n")
            [System.IO.File]::WriteAllBytes($envPath, $sentinel)

            Copy-Payload -Root $root -Destination $destination

            [System.IO.File]::ReadAllBytes($envPath) | Should -Be $sentinel
        }

        It 'does not write a .env when the destination has none' {
            Copy-Payload -Root $root -Destination $destination
            Join-Path $destination '.env' | Should -Not -Exist
        }
    }
}
