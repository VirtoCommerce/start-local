BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    function script:New-ModuleFolder {
        # A folder under TestDrive. With $ModuleId it holds a module.manifest, as a module's *.Web folder does.
        param([string]$Name, [string]$ModuleId)

        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $path = Join-Path $folder $Name
        $null = New-Item -ItemType Directory -Path $path -Force
        if ($ModuleId) {
            Set-Content -LiteralPath (Join-Path $path 'module.manifest') -Value "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<module xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">`n  <id>$ModuleId</id>`n  <version>3.0.0</version>`n</module>"
        }
        $path
    }

    function script:Get-Slashed {
        param([string]$Path)
        $Path -replace '\\', '/'
    }
}

Describe 'SourceMode' -Tag 'Unit' {
    Context 'Split-ModuleSourcePaths' {
        It 'splits on semicolons, trims, and drops empty entries' {
            $entries = Split-ModuleSourcePaths ' /a/One.Web ;; C:\b\Two.Web; '

            $entries | Should -Be @('/a/One.Web', 'C:\b\Two.Web')
        }

        It 'returns an empty array for an empty value' {
            $entries = Split-ModuleSourcePaths ''

            @($entries).Count | Should -Be 0
            ($entries -is [string[]]) | Should -BeTrue
        }
    }

    Context 'Get-ModuleIdFromManifestText' {
        It 'reads the id of the module' {
            Get-ModuleIdFromManifestText '<module><id>VirtoCommerce.Catalog</id></module>' | Should -BeExactly 'VirtoCommerce.Catalog'
        }

        It 'reads the id of a manifest with a namespace, a declaration and other elements' {
            $text = "<?xml version=`"1.0`"?>`n<module xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`"><version>3.0</version><id> VirtoCommerce.Cart </id></module>"

            Get-ModuleIdFromManifestText $text | Should -BeExactly 'VirtoCommerce.Cart'
        }

        It 'returns $null for text that is not a manifest with an id' -TestCases @(
            @{ Text = '' }
            @{ Text = 'not xml' }
            @{ Text = '<module><version>1</version></module>' }
            @{ Text = '<other><id>A</id></other>' }
            @{ Text = '<module><id>  </id></module>' }
        ) {
            Get-ModuleIdFromManifestText $Text | Should -BeNullOrEmpty
        }

        It 'rejects an id that is not one plain folder name' -TestCases @(
            @{ Id = '../evil' }
            @{ Id = 'a/b' }
            @{ Id = '..' }
        ) {
            Get-ModuleIdFromManifestText "<module><id>$Id</id></module>" | Should -BeNullOrEmpty
        }
    }

    Context 'Get-ModuleSourceKind' {
        It 'two *.Web folders with a module.manifest are webfolders' {
            $catalog = New-ModuleFolder 'VirtoCommerce.CatalogModule.Web' 'VirtoCommerce.Catalog'
            $cart = New-ModuleFolder 'VirtoCommerce.CartModule.Web' 'VirtoCommerce.Cart'

            $result = Get-ModuleSourceKind -Paths @($catalog, $cart)

            $result.Kind | Should -Be 'webfolders'
            @($result.Entries).Count | Should -Be 2
            ($result.Entries | ForEach-Object { $_.ModuleId }) | Should -Be @('VirtoCommerce.Catalog', 'VirtoCommerce.Cart')
        }

        It 'a folder without a manifest is a modulesfolder, empty or not' {
            $empty = New-ModuleFolder 'modules'
            $filled = New-ModuleFolder 'modules'
            $null = New-Item -ItemType Directory -Path (Join-Path $filled 'VirtoCommerce.Catalog') -Force
            Set-Content -LiteralPath (Join-Path $filled 'VirtoCommerce.Catalog/module.manifest') -Value '<module><id>VirtoCommerce.Catalog</id></module>'

            (Get-ModuleSourceKind -Paths @($empty)).Kind | Should -Be 'modulesfolder'
            (Get-ModuleSourceKind -Paths @($filled)).Kind | Should -Be 'modulesfolder'
        }

        It 'one of each is mixed, and says so' {
            $web = New-ModuleFolder 'A.Web' 'A'
            $modules = New-ModuleFolder 'modules'

            $result = Get-ModuleSourceKind -Paths @($web, $modules)

            $result.Kind | Should -Be 'mixed'
            $result.Message | Should -Match 'MODULE_SOURCE_PATHS'
        }

        It 'a missing path is invalid, and the message names it' {
            $missing = Join-Path $TestDrive 'no-such-folder'

            $result = Get-ModuleSourceKind -Paths @($missing)

            $result.Kind | Should -Be 'invalid'
            $result.Message | Should -Match 'MODULE_SOURCE_PATHS'
            $result.Message | Should -BeLike '*no-such-folder*'
        }

        It 'a file instead of a folder is invalid' {
            $folder = New-ModuleFolder 'modules'
            $file = Join-Path $folder 'readme.txt'
            Set-Content -LiteralPath $file -Value 'x'

            (Get-ModuleSourceKind -Paths @($file)).Kind | Should -Be 'invalid'
        }

        It 'a module.manifest without an id is invalid' {
            $folder = New-ModuleFolder 'Broken.Web'
            Set-Content -LiteralPath (Join-Path $folder 'module.manifest') -Value '<module></module>'

            $result = Get-ModuleSourceKind -Paths @($folder)

            $result.Kind | Should -Be 'invalid'
            $result.Message | Should -BeLike '*module.manifest*'
        }

        It 'two modules folders are invalid' {
            $result = Get-ModuleSourceKind -Paths @((New-ModuleFolder 'modules'), (New-ModuleFolder 'modules'))

            $result.Kind | Should -Be 'invalid'
        }

        It 'the same module id twice is invalid' {
            $result = Get-ModuleSourceKind -Paths @((New-ModuleFolder 'A.Web' 'Same'), (New-ModuleFolder 'B.Web' 'Same'))

            $result.Kind | Should -Be 'invalid'
            $result.Message | Should -BeLike '*Same*'
        }

        It 'an empty value is none' {
            $result = Get-ModuleSourceKind -Paths @()

            $result.Kind | Should -Be 'none'
            @($result.Entries).Count | Should -Be 0
        }

        It 'resolves a relative path against the current folder and drops a trailing separator' {
            $folder = New-ModuleFolder 'Rel.Web' 'Rel'
            Push-Location -LiteralPath (Split-Path $folder -Parent)
            try {
                $result = Get-ModuleSourceKind -Paths @('./Rel.Web/')
            }
            finally {
                Pop-Location
            }

            $result.Kind | Should -Be 'webfolders'
            (Get-Slashed $result.Entries[0].Path) | Should -Be (Get-Slashed $folder)
        }
    }

    Context 'Get-ModuleMountPlan' {
        It 'mounts each *.Web folder at the platform modules folder under its module id' {
            $catalog = New-ModuleFolder 'VirtoCommerce.CatalogModule.Web' 'VirtoCommerce.Catalog'
            $cart = New-ModuleFolder 'VirtoCommerce.CartModule.Web' 'VirtoCommerce.Cart'

            $plan = Get-ModuleMountPlan -Classification (Get-ModuleSourceKind -Paths @($catalog, $cart))

            @($plan).Count | Should -Be 2
            $plan[0].Target | Should -BeExactly '/opt/virtocommerce/platform/modules/VirtoCommerce.Catalog'
            $plan[1].Target | Should -BeExactly '/opt/virtocommerce/platform/modules/VirtoCommerce.Cart'
            (Get-Slashed $plan[0].Source) | Should -Be (Get-Slashed $catalog)
        }

        It 'mounts a modules folder at the platform modules folder itself' {
            $modules = New-ModuleFolder 'modules'

            $plan = Get-ModuleMountPlan -Classification (Get-ModuleSourceKind -Paths @($modules))

            @($plan).Count | Should -Be 1
            $plan[0].Target | Should -BeExactly '/opt/virtocommerce/platform/modules'
            (Get-Slashed $plan[0].Source) | Should -Be (Get-Slashed $modules)
        }

        It 'plans nothing for none, mixed and invalid' {
            foreach ($paths in @(@(), @((New-ModuleFolder 'A.Web' 'A'), (New-ModuleFolder 'modules')), @((Join-Path $TestDrive 'missing')))) {
                $plan = Get-ModuleMountPlan -Classification (Get-ModuleSourceKind -Paths $paths)

                @($plan).Count | Should -Be 0
            }
        }
    }

    Context 'New-ModulesComposeYaml and Write-ModulesComposeFile' {
        It 'writes one long-syntax bind mount per plan entry on the platform service' {
            $plan = @(
                [pscustomobject]@{ Source = '/src/Catalog.Web'; Target = '/opt/virtocommerce/platform/modules/VirtoCommerce.Catalog' }
                [pscustomobject]@{ Source = '/src/Cart.Web'; Target = '/opt/virtocommerce/platform/modules/VirtoCommerce.Cart' }
            )

            $yaml = New-ModulesComposeYaml -MountPlan $plan

            $yaml | Should -Match '(?m)^  vc-platform-web:$'
            ([regex]::Matches($yaml, '(?m)^      - type: bind$')).Count | Should -Be 2
            $yaml | Should -Match '(?m)^        source: "/src/Catalog.Web"$'
            $yaml | Should -Match '(?m)^        target: "/opt/virtocommerce/platform/modules/VirtoCommerce.Cart"$'
            $yaml | Should -Not -Match "`r"
        }

        It 'escapes a Windows path, a quote, and a dollar sign (Compose interpolates it)' {
            $plan = @([pscustomobject]@{ Source = 'C:\src\my "mods"\$HOME'; Target = '/opt/virtocommerce/platform/modules' })

            $yaml = New-ModulesComposeYaml -MountPlan $plan

            $yaml | Should -Match ([regex]::Escape('source: "C:\\src\\my \"mods\"\\$$HOME"'))
        }

        It 'writes the file into the solution folder without a BOM' {
            $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $folder
            $plan = @([pscustomobject]@{ Source = '/src/A.Web'; Target = '/opt/virtocommerce/platform/modules/A' })

            Write-ModulesComposeFile -SolutionFolder $folder -MountPlan $plan

            $path = Join-Path $folder 'docker-compose.platform-modules.yml'
            $path | Should -Exist
            [System.IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF
            Get-Content -LiteralPath $path -Raw | Should -Be (New-ModulesComposeYaml -MountPlan $plan)
        }

        It 'deletes the file when the plan is empty, and accepts a missing file' {
            $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $folder
            $path = Join-Path $folder 'docker-compose.platform-modules.yml'
            Set-Content -LiteralPath $path -Value 'services: {}'

            Write-ModulesComposeFile -SolutionFolder $folder -MountPlan @()
            $path | Should -Not -Exist

            { Write-ModulesComposeFile -SolutionFolder $folder -MountPlan @() } | Should -Not -Throw
        }
    }

    Context 'Test-FileSharing' {
        It 'throws for a folder that does not exist' {
            { Test-FileSharing -Path (Join-Path $TestDrive 'no-such-folder') } | Should -Throw -ExceptionType ([System.IO.DirectoryNotFoundException])
        }
    }

    Context 'Invoke-Preflight' {
        BeforeEach {
            Mock Test-DockerRunning { $true }
            Mock Get-ComposeVersion { '2.40.3' }
            Mock Get-ProjectPublishedPorts { [int[]]@() }
            Mock Test-PortInUse { $false }
            Mock Test-FileSharing { $true }

            $script:dockerStack = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml', 'docker-compose.platform.yml')
        }

        function script:New-SourceModulesEnv {
            param([string]$Paths)
            [ordered]@{
                COMPOSE_FILE        = 'docker-compose.yml;docker-compose.postgres.yml;docker-compose.platform.yml'
                RELEASE_CHANNEL     = 'stable'
                PGSQL_PORT          = '5432'
                PLATFORM_PORT       = '8090'
                MODULE_SOURCE_PATHS = $Paths
            }
        }

        It 'reports mixed form' {
            $paths = (New-ModuleFolder 'A.Web' 'A'), (New-ModuleFolder 'modules') -join ';'

            $errors = Invoke-Preflight -EnvValues (New-SourceModulesEnv $paths) -ComposeFiles $script:dockerStack -NonInteractive $true

            ($errors -join "`n") | Should -Match 'MODULE_SOURCE_PATHS'
            Should -Invoke Test-FileSharing -Times 0
        }

        It 'reports mounts denied and names File sharing' {
            Mock Test-FileSharing { $false }
            $web = New-ModuleFolder 'A.Web' 'A'

            $errors = Invoke-Preflight -EnvValues (New-SourceModulesEnv $web) -ComposeFiles $script:dockerStack -NonInteractive $true

            @($errors).Count | Should -Be 1
            $errors[0] | Should -Match 'File sharing'
            $errors[0] | Should -BeLike "*$web*"
        }

        It 'probes each mounted folder of a Docker platform and reports nothing when Docker can mount them' {
            $first = New-ModuleFolder 'A.Web' 'A'
            $second = New-ModuleFolder 'B.Web' 'B'

            $errors = Invoke-Preflight -EnvValues (New-SourceModulesEnv "$first;$second") -ComposeFiles $script:dockerStack -NonInteractive $true

            @($errors).Count | Should -Be 0
            Should -Invoke Test-FileSharing -Times 2 -Exactly
        }

        It 'reports a probe that fails for another reason' {
            Mock Test-FileSharing { throw [System.InvalidOperationException]::new('docker run failed: no such image') }
            $web = New-ModuleFolder 'A.Web' 'A'

            $errors = Invoke-Preflight -EnvValues (New-SourceModulesEnv $web) -ComposeFiles $script:dockerStack -NonInteractive $true

            ($errors -join "`n") | Should -Match 'File sharing'
            ($errors -join "`n") | Should -Match 'no such image'
        }

        It 'skips the file sharing probe when the platform is not a Docker platform' {
            $files = [string[]]@('docker-compose.yml', 'docker-compose.postgres.yml')

            $errors = Invoke-Preflight -EnvValues (New-SourceModulesEnv (New-ModuleFolder 'A.Web' 'A')) -ComposeFiles $files -NonInteractive $true

            @($errors).Count | Should -Be 0
            Should -Invoke Test-FileSharing -Times 0
        }

        It 'reports an empty MODULE_SOURCE_PATHS as fine' {
            $errors = Invoke-Preflight -EnvValues (New-SourceModulesEnv '') -ComposeFiles $script:dockerStack -NonInteractive $true

            @($errors).Count | Should -Be 0
            Should -Invoke Test-FileSharing -Times 0
        }
    }
}
