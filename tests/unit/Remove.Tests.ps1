# Defined outside BeforeAll: Pester reads -Skip at discovery time.
$composeMissing = $true
if (Get-Command docker -CommandType Application -ErrorAction Ignore) {
    $null = & docker compose version 2>&1
    $composeMissing = $LASTEXITCODE -ne 0
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    $script:RemoveScript = Join-Path (Get-TestRepositoryRoot) 'remove.ps1'

    # A solution folder with a .env that holds the given lines. -Name decides the Compose project name.
    function script:New-RemoveFolder {
        param([string]$Name = 'VirtoLocal', [string[]]$EnvLines = @('START_LOCAL_LAYOUT=2', 'VOLUME_PREFIX='))
        $folder = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))/$Name"
        $null = New-Item -ItemType Directory -Path $folder -Force
        Set-Content -LiteralPath (Join-Path $folder '.env') -Value $EnvLines
        $folder
    }

    function script:Invoke-RemoveScript {
        param([string[]]$Arguments)
        $output = & pwsh -NoProfile -File $script:RemoveScript @Arguments *>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
}

Describe 'Remove' -Tag 'Unit' {
    Context 'Test-RemovableFolder' {
        It 'refuses a git checkout' {
            $folder = New-RemoveFolder
            $null = New-Item -ItemType Directory -Path (Join-Path $folder '.git')
            Test-RemovableFolder -Folder $folder | Should -BeFalse
        }

        It 'refuses a worktree, whose .git is a file' {
            $folder = New-RemoveFolder
            Set-Content -LiteralPath (Join-Path $folder '.git') -Value 'gitdir: ../elsewhere'
            Test-RemovableFolder -Folder $folder | Should -BeFalse
        }

        It 'accepts a folder without .git' {
            Test-RemovableFolder -Folder (New-RemoveFolder) | Should -BeTrue
        }
    }

    Context 'Get-RemovalPlan' {
        It 'full plan: down -v, the eight volumes of VOLUME_PREFIX, both images, the folder' {
            $folder = New-RemoveFolder -Name 'Shop One' -EnvLines 'VOLUME_PREFIX=acme'
            $plan = Get-RemovalPlan -Folder $folder -KeepData $false
            $plan.DownArgs | Should -Be @('down', '-v', '--remove-orphans')
            $plan.Volumes | Should -Be (Get-SolutionVolumeNames -Prefix 'acme')
            $plan.Volumes | Should -HaveCount 8
            $plan.Images | Should -Be @('vc-platform:shopone-latest', 'vc-frontend:shopone-latest')
            $plan.DeletePaths | Should -Be @($folder)
        }

        It 'uses COMPOSE_PROJECT_NAME for the prefix and the images when VOLUME_PREFIX is empty' {
            $folder = New-RemoveFolder -EnvLines 'VOLUME_PREFIX=', 'COMPOSE_PROJECT_NAME=demo'
            $plan = Get-RemovalPlan -Folder $folder -KeepData $false
            $plan.Volumes[0] | Should -BeExactly 'demo_postgres_data'
            $plan.Images[0] | Should -BeExactly 'vc-platform:demo-latest'
        }

        It 'falls back to the folder name for the prefix and the images' {
            $folder = New-RemoveFolder -Name 'My_Shop' -EnvLines 'VOLUME_PREFIX='
            $plan = Get-RemovalPlan -Folder $folder -KeepData $false
            $plan.Volumes[0] | Should -BeExactly 'my_shop_postgres_data'
            $plan.Images[1] | Should -BeExactly 'vc-frontend:my_shop-latest'
        }

        It 'keepData plan: down without -v, no volumes, every child but .env' {
            $folder = New-RemoveFolder -EnvLines 'VOLUME_PREFIX=acme'
            foreach ($child in 'start.ps1', 'docker-compose.yml', '.env.example', '.hidden') {
                $null = New-Item -ItemType File -Path (Join-Path $folder $child)
            }
            $null = New-Item -ItemType Directory -Path (Join-Path $folder 'backend/publish') -Force
            $plan = Get-RemovalPlan -Folder $folder -KeepData $true
            $plan.DownArgs | Should -Be @('down', '--remove-orphans')
            @($plan.Volumes) | Should -HaveCount 0
            $plan.Images | Should -HaveCount 2
            $names = $plan.DeletePaths | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object
            $names | Should -Be @('.env.example', '.hidden', 'backend', 'docker-compose.yml', 'start.ps1')
            ($plan.DeletePaths | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique) | Should -Be @($folder)
        }

        It 'keepData plan of a folder that holds only .env deletes nothing' {
            $plan = Get-RemovalPlan -Folder (New-RemoveFolder) -KeepData $true
            @($plan.DeletePaths) | Should -HaveCount 0
        }

        It 'names the virto_* volumes of a migrated layout 1 folder' {
            $folder = New-RemoveFolder -Name 'VirtoLocal' -EnvLines 'DB_PROVIDER=postgres', 'DB_PASSWORD=secret'
            $template = Read-EnvFile -Path (Join-Path (Get-TestRepositoryRoot) '.env.example')
            $migration = Convert-EnvToLayout2 -Document (Read-EnvFile -Path (Join-Path $folder '.env')) -Template $template
            Write-EnvFile -Document $migration.Document -Path (Join-Path $folder '.env')
            $plan = Get-RemovalPlan -Folder $folder -KeepData $false
            $plan.Volumes | Should -Contain 'virto_postgres_data'
            $plan.Volumes | Should -Contain 'virto_redisdata'
            $plan.Images | Should -Be @('vc-platform:virtolocal-latest', 'vc-frontend:virtolocal-latest')
        }

        It 'works on a folder without .env, using the folder name' {
            $folder = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))/Bare"
            $null = New-Item -ItemType Directory -Path $folder -Force
            (Get-RemovalPlan -Folder $folder -KeepData $false).Volumes[0] | Should -BeExactly 'bare_postgres_data'
        }
    }

    Context 'remove.ps1' {
        It 'refuses a git checkout and leaves it untouched' {
            $folder = New-RemoveFolder
            $null = New-Item -ItemType Directory -Path (Join-Path $folder '.git')
            $result = Invoke-RemoveScript @('-solutionFolder', $folder, '-nonInteractive')
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'git'
            Test-Path -LiteralPath (Join-Path $folder '.env') | Should -BeTrue
        }

        It 'removes the folder it is run from' -Skip:$composeMissing {
            # A unique folder name keeps the volume and image names it derives from matching nothing real.
            $folder = New-RemoveFolder -Name "rm-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
            Push-Location -LiteralPath $folder
            try {
                $result = Invoke-RemoveScript @('-nonInteractive', '-solutionFolder', $folder)
            }
            finally {
                Pop-Location
            }
            $result.ExitCode | Should -Be 0
            Test-Path -LiteralPath $folder | Should -BeFalse
        }

        It 'stops on a folder that has no .env' {
            $folder = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N'))/NoEnv"
            $null = New-Item -ItemType Directory -Path $folder -Force
            $result = Invoke-RemoveScript @('-solutionFolder', $folder, '-nonInteractive')
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match '\.env'
            Test-Path -LiteralPath $folder | Should -BeTrue
        }
    }
}
