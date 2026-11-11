BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

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

Describe 'Platform from source' -Tag 'Unit' {
    BeforeAll {
        # A vc-platform checkout or a prebuilt platform folder in TestDrive.
        function script:New-PlatformFolder {
            param([ValidateSet('checkout', 'prebuilt', 'empty')][string]$Kind, [switch]$Built)

            $folder = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) 'platform'
            $null = New-Item -ItemType Directory -Path $folder -Force
            switch ($Kind) {
                'checkout' {
                    $web = Join-Path $folder 'src/VirtoCommerce.Platform.Web'
                    $null = New-Item -ItemType Directory -Path $web -Force
                    Set-Content -LiteralPath (Join-Path $web 'VirtoCommerce.Platform.Web.csproj') -Value '<Project />'
                    if ($Built) {
                        $null = New-Item -ItemType Directory -Path (Join-Path $web 'bin/Debug/net10.0') -Force
                        Set-Content -LiteralPath (Join-Path $web 'bin/Debug/net10.0/VirtoCommerce.Platform.Web.dll') -Value 'x'
                    }
                }
                'prebuilt' {
                    if ($Built) {
                        Set-Content -LiteralPath (Join-Path $folder 'VirtoCommerce.Platform.Web.dll') -Value 'x'
                    }
                }
            }
            $folder
        }

        # A child process that sleeps; the caller kills it. -ChildPidFile makes it start a sleeping child of its own.
        function script:Start-SleepingPwsh {
            param([string]$ChildPidFile)

            $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $script = if ($ChildPidFile) {
                @"
`$childInfo = [System.Diagnostics.ProcessStartInfo]::new('$((Get-Process -Id $PID).Path)')
foreach (`$argument in '-NoProfile', '-Command', 'Start-Sleep -Seconds 120') { `$childInfo.ArgumentList.Add(`$argument) }
`$child = [System.Diagnostics.Process]::Start(`$childInfo)
Set-Content -LiteralPath '$ChildPidFile' -Value `$child.Id
`$child.WaitForExit()
"@
            }
            else {
                'Start-Sleep -Seconds 120'
            }
            foreach ($argument in '-NoProfile', '-Command', $script) {
                $info.ArgumentList.Add($argument)
            }
            $info.UseShellExecute = $false
            [System.Diagnostics.Process]::Start($info)
        }

        function script:Wait-Until {
            param([scriptblock]$Condition, [int]$Seconds = 30)

            $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
            while (-not (& $Condition) -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 200
            }
            [bool](& $Condition)
        }

        function script:Test-ProcessGone {
            param([int]$ProcessId)

            $process = Get-Process -Id $ProcessId -ErrorAction Ignore
            # A killed process that nobody has reaped yet is a zombie: it still has a pid but has exited.
            (-not $process) -or $process.HasExited
        }

        function script:Write-PidFile {
            param([string]$LogDir, [System.Diagnostics.Process]$Process, [long]$StartTicksOffset = 0)

            $null = New-Item -ItemType Directory -Path $LogDir -Force
            Set-Content -LiteralPath (Join-Path $LogDir 'platform.pid') -Value "$($Process.Id);$($Process.StartTime.ToUniversalTime().Ticks + $StartTicksOffset)"
        }
    }

    Context 'source kind detection' {
        It 'recognizes a checkout by its Web project' {
            Get-PlatformSourceKind -Path (New-PlatformFolder checkout) | Should -BeExactly 'checkout'
        }

        It 'recognizes a prebuilt folder by VirtoCommerce.Platform.Web.dll' {
            Get-PlatformSourceKind -Path (New-PlatformFolder prebuilt -Built) | Should -BeExactly 'prebuilt'
        }

        It 'gives $null for a folder that is neither' {
            Get-PlatformSourceKind -Path (New-PlatformFolder empty) | Should -BeNullOrEmpty
        }

        It 'gives $null for a path that does not exist' {
            Get-PlatformSourceKind -Path (Join-Path $TestDrive 'nope') | Should -BeNullOrEmpty
        }
    }

    Context 'content root and build output' {
        It 'puts the content root of a checkout in src/VirtoCommerce.Platform.Web, and of a prebuilt folder in the folder' {
            (Get-PlatformContentRoot -Path '/p' -Kind checkout) -replace '\\', '/' | Should -Be '/p/src/VirtoCommerce.Platform.Web'
            (Get-PlatformContentRoot -Path '/p' -Kind prebuilt) | Should -Be '/p'
        }

        It 'finds a built checkout in bin/**, and an unbuilt one has none' {
            Test-PlatformBuildOutput -Path (New-PlatformFolder checkout -Built) -Kind checkout | Should -BeTrue
            Test-PlatformBuildOutput -Path (New-PlatformFolder checkout) -Kind checkout | Should -BeFalse
        }

        It 'finds the dll of a prebuilt folder' {
            Test-PlatformBuildOutput -Path (New-PlatformFolder prebuilt -Built) -Kind prebuilt | Should -BeTrue
            Test-PlatformBuildOutput -Path (New-PlatformFolder prebuilt) -Kind prebuilt | Should -BeFalse
        }
    }

    Context 'command lines' {
        It 'runs a checkout with dotnet run --no-build in its content root' {
            $path = New-PlatformFolder checkout -Built

            $command = Get-SourcePlatformCommand -Path $path -Kind checkout

            $command.FilePath | Should -Be 'dotnet'
            $contentRoot = Join-Path $path 'src/VirtoCommerce.Platform.Web'
            $command.Arguments | Should -Be @('run', '--no-build', '--project', $contentRoot)
            $command.WorkingDirectory | Should -Be $contentRoot
        }

        It 'runs a prebuilt folder with dotnet VirtoCommerce.Platform.Web.dll in the folder' {
            $path = New-PlatformFolder prebuilt -Built

            $command = Get-SourcePlatformCommand -Path $path -Kind prebuilt

            $command.FilePath | Should -Be 'dotnet'
            $command.Arguments | Should -Be @('VirtoCommerce.Platform.Web.dll')
            $command.WorkingDirectory | Should -Be $path
        }
    }

    Context 'link plans' {
        It 'links each *.Web folder as modules/(module id) in the content root' {
            $classification = Get-ModuleSourceKind -Paths @((New-ModuleFolder 'A.Web' 'VirtoCommerce.A'), (New-ModuleFolder 'B.Web' 'VirtoCommerce.B'))

            $plan = Get-ModuleLinkPlan -Classification $classification -ContentRoot '/root'

            @($plan).Count | Should -Be 2
            $plan[0].LinkPath -replace '\\', '/' | Should -Be '/root/modules/VirtoCommerce.A'
            $plan[0].Target | Should -Be $classification.Entries[0].Path
            $plan[1].LinkPath -replace '\\', '/' | Should -Be '/root/modules/VirtoCommerce.B'
        }

        It 'links a modules folder as the content root modules folder' {
            $modules = New-ModuleFolder 'modules'
            $classification = Get-ModuleSourceKind -Paths @($modules)

            $plan = Get-ModuleLinkPlan -Classification $classification -ContentRoot '/root'

            @($plan).Count | Should -Be 1
            $plan[0].LinkPath -replace '\\', '/' | Should -Be '/root/modules'
            $plan[0].Target | Should -Be $classification.Entries[0].Path
        }

        It 'plans nothing without module sources' {
            $plan = Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @()) -ContentRoot '/root'

            @($plan).Count | Should -Be 0
        }
    }

    Context 'Set-ModuleLinks' {
        It 'links each *.Web folder and a second run changes nothing' -Skip:$IsWindows {
            $root = New-ModuleFolder 'root'
            $web = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'
            $plan = Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @($web)) -ContentRoot $root

            Set-ModuleLinks -LinkPlan $plan | Should -BeNullOrEmpty
            Set-ModuleLinks -LinkPlan $plan | Should -BeNullOrEmpty

            $link = Get-Item -LiteralPath (Join-Path $root 'modules/VirtoCommerce.A')
            $link.LinkTarget | Should -Be $web
            Join-Path $root 'modules/VirtoCommerce.A/module.manifest' | Should -Exist
        }

        It 'links a modules folder as <root>/modules, and replaces a link that points elsewhere without touching its target' -Skip:$IsWindows {
            $root = New-ModuleFolder 'root'
            $old = New-ModuleFolder 'old-modules'
            Set-Content -LiteralPath (Join-Path $old 'keep.txt') -Value 'x'
            $new = New-ModuleFolder 'new-modules'
            $null = [System.IO.Directory]::CreateSymbolicLink((Join-Path $root 'modules'), $old)

            $plan = Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @($new)) -ContentRoot $root
            Set-ModuleLinks -LinkPlan $plan | Should -BeNullOrEmpty

            (Get-Item -LiteralPath (Join-Path $root 'modules')).LinkTarget | Should -Be $new
            Join-Path $old 'keep.txt' | Should -Exist
        }

        It 'relinks a *.Web link whose old target is gone (a moved checkout)' -Skip:$IsWindows {
            $root = New-ModuleFolder 'root'
            $old = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'modules')
            $null = [System.IO.Directory]::CreateSymbolicLink((Join-Path $root 'modules/VirtoCommerce.A'), $old)
            Remove-Item -LiteralPath $old -Recurse -Force
            $new = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'

            $plan = Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @($new)) -ContentRoot $root
            { Set-ModuleLinks -LinkPlan $plan | Should -BeNullOrEmpty } | Should -Not -Throw

            (Get-Item -LiteralPath (Join-Path $root 'modules/VirtoCommerce.A')).LinkTarget | Should -Be $new
            Join-Path $root 'modules/VirtoCommerce.A/module.manifest' | Should -Exist
        }

        It 'relinks a modules link whose old target is gone' -Skip:$IsWindows {
            $root = New-ModuleFolder 'root'
            $old = New-ModuleFolder 'old-modules'
            $null = [System.IO.Directory]::CreateSymbolicLink((Join-Path $root 'modules'), $old)
            Remove-Item -LiteralPath $old -Recurse -Force
            $new = New-ModuleFolder 'new-modules'

            $plan = Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @($new)) -ContentRoot $root
            { Set-ModuleLinks -LinkPlan $plan | Should -BeNullOrEmpty } | Should -Not -Throw

            (Get-Item -LiteralPath (Join-Path $root 'modules')).LinkTarget | Should -Be $new
        }

        It 'replaces an empty real modules folder with the link' -Skip:$IsWindows {
            $root = New-ModuleFolder 'root'
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'modules')
            $new = New-ModuleFolder 'new-modules'

            $plan = Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @($new)) -ContentRoot $root

            Set-ModuleLinks -LinkPlan $plan | Should -BeNullOrEmpty
            (Get-Item -LiteralPath (Join-Path $root 'modules')).LinkTarget | Should -Be $new
        }

        It 'refuses a real non-empty modules dir and names it' {
            $root = New-ModuleFolder 'root'
            $modules = Join-Path $root 'modules'
            $null = New-Item -ItemType Directory -Path (Join-Path $modules 'Installed.Module') -Force
            $new = New-ModuleFolder 'new-modules'

            $plan = Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @($new)) -ContentRoot $root
            $message = Set-ModuleLinks -LinkPlan $plan

            $message | Should -BeLike "*$modules*"
            Join-Path $modules 'Installed.Module' | Should -Exist
        }

        It 'refuses an installed module folder where a *.Web folder would be linked, and names it' {
            $root = New-ModuleFolder 'root'
            $installed = Join-Path $root 'modules/VirtoCommerce.A'
            $null = New-Item -ItemType Directory -Path $installed -Force
            Set-Content -LiteralPath (Join-Path $installed 'VirtoCommerce.A.dll') -Value 'x'
            $web = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'

            $message = Set-ModuleLinks -LinkPlan (Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @($web)) -ContentRoot $root)

            $message | Should -BeLike "*$installed*"
            Join-Path $installed 'VirtoCommerce.A.dll' | Should -Exist
        }

        It 'does not link *.Web folders into a modules folder that is itself a link' -Skip:$IsWindows {
            $root = New-ModuleFolder 'root'
            $user = New-ModuleFolder 'users-modules'
            $null = [System.IO.Directory]::CreateSymbolicLink((Join-Path $root 'modules'), $user)
            $web = New-ModuleFolder 'A.Web' 'VirtoCommerce.A'

            $message = Set-ModuleLinks -LinkPlan (Get-ModuleLinkPlan -Classification (Get-ModuleSourceKind -Paths @($web)) -ContentRoot $root)

            $message | Should -BeLike "*$(Join-Path $root 'modules')*"
            @(Get-ChildItem -LiteralPath $user -Force).Count | Should -Be 0
        }

        It 'succeeds with an empty plan' {
            Set-ModuleLinks -LinkPlan @() | Should -BeNullOrEmpty
        }
    }

    Context 'Test-SymlinkRights' {
        It 'is true where symlinks need no special rights' -Skip:$IsWindows {
            Test-SymlinkRights | Should -BeTrue
        }

        It 'answers with a boolean' {
            Test-SymlinkRights | Should -BeOfType [bool]
        }
    }

    Context 'Add-GitInfoExclude' {
        It 'is idempotent: the first call adds the entry, the second does not, and the entry stays once' {
            $checkout = New-PlatformFolder checkout
            $null = New-Item -ItemType Directory -Path (Join-Path $checkout '.git')

            Add-GitInfoExclude -CheckoutPath $checkout -Entry 'VirtoCommerce.Platform.Web.settings.json' | Should -BeTrue
            Add-GitInfoExclude -CheckoutPath $checkout -Entry 'VirtoCommerce.Platform.Web.settings.json' | Should -BeFalse

            $lines = Get-Content -LiteralPath (Join-Path $checkout '.git/info/exclude')
            @($lines | Where-Object { $_ -eq 'VirtoCommerce.Platform.Web.settings.json' }).Count | Should -Be 1
        }

        It 'keeps the lines that are there and starts a new line after one without a line break' {
            $checkout = New-PlatformFolder checkout
            $exclude = Join-Path $checkout '.git/info/exclude'
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $exclude) -Force
            [System.IO.File]::WriteAllText($exclude, '# mine')

            Add-GitInfoExclude -CheckoutPath $checkout -Entry 'a.json' | Should -BeTrue

            Get-Content -LiteralPath $exclude | Should -Be @('# mine', 'a.json')
        }

        It 'returns $false for a folder that is not a checkout' {
            Add-GitInfoExclude -CheckoutPath (New-PlatformFolder checkout) -Entry 'a.json' | Should -BeFalse
        }

        It 'follows the .git file of a worktree to the shared info/exclude' {
            $checkout = New-PlatformFolder checkout
            $common = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $worktreeGitDir = Join-Path $common 'worktrees/w1'
            $null = New-Item -ItemType Directory -Path $worktreeGitDir -Force
            Set-Content -LiteralPath (Join-Path $worktreeGitDir 'commondir') -Value '../..'
            Set-Content -LiteralPath (Join-Path $checkout '.git') -Value "gitdir: $worktreeGitDir"

            Add-GitInfoExclude -CheckoutPath $checkout -Entry 'a.json' | Should -BeTrue

            Get-Content -LiteralPath (Join-Path $common 'info/exclude') | Should -Be @('a.json')
        }
    }

    Context 'Start-SourcePlatform and Stop-SourcePlatform' {
        It 'launches the command in its working directory as Development, records the pid and start time, and stops it' {
            $workingDirectory = Join-Path $TestDrive 'wd'
            $null = New-Item -ItemType Directory -Path $workingDirectory
            $logDir = Join-Path $TestDrive 'logs'
            $command = [pscustomobject]@{
                FilePath         = (Get-Process -Id $PID).Path
                Arguments        = [string[]]@('-NoProfile', '-Command', 'Write-Output "env=$env:ASPNETCORE_ENVIRONMENT"; Write-Output "cwd=$((Get-Location).Path)"; Start-Sleep -Seconds 120')
                WorkingDirectory = $workingDirectory
            }

            $processId = Start-SourcePlatform -Command $command -LogDir $logDir
            try {
                $processId | Should -BeOfType [int]
                (Get-Content -LiteralPath (Join-Path $logDir 'platform.pid') -Raw).Trim() |
                    Should -Match "^$processId;\d+$"
                Wait-Until { (Test-Path -LiteralPath (Join-Path $logDir 'platform.log')) -and ((Get-Content -LiteralPath (Join-Path $logDir 'platform.log') -Raw) -like '*cwd=*') } | Should -BeTrue
                $log = Get-Content -LiteralPath (Join-Path $logDir 'platform.log') -Raw
                $log | Should -BeLike '*env=Development*'
                ($log -replace '\\', '/') | Should -BeLike "*cwd=$(($workingDirectory -replace '\\', '/'))*"
                Test-ProcessGone $processId | Should -BeFalse

                Stop-SourcePlatform -LogDir $logDir | Should -BeTrue

                Wait-Until { Test-ProcessGone $processId } | Should -BeTrue
                Join-Path $logDir 'platform.pid' | Should -Not -Exist
            }
            finally {
                Get-Process -Id $processId -ErrorAction Ignore | Stop-Process -Force -ErrorAction Ignore
            }
        }

        It 'keeps the platform running when the launching terminal sends SIG<Signal> to its process group (<Scenario>)' -Skip:($IsWindows -or -not (Get-Command perl -CommandType Application -ErrorAction Ignore)) -ForEach @(
            @{ Signal = 'INT'; Scenario = 'setsid where the host has it'; WithoutSetsid = $false }
            @{ Signal = 'HUP'; Scenario = 'setsid where the host has it'; WithoutSetsid = $false }
            @{ Signal = 'INT'; Scenario = 'no setsid on PATH'; WithoutSetsid = $true }
            @{ Signal = 'HUP'; Scenario = 'no setsid on PATH'; WithoutSetsid = $true }
        ) {
            $logDir = Join-Path $TestDrive "logs-$Signal-$WithoutSetsid"
            $childPidFile = Join-Path $TestDrive "child-$Signal-$WithoutSetsid.pid"
            $launcher = Join-Path $TestDrive "launcher-$Signal-$WithoutSetsid.ps1"
            $initScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../scripts/_init.ps1')).ProviderPath
            Set-Content -LiteralPath $launcher -Value @"
. '$initScript'
`$command = [pscustomobject]@{ FilePath = 'sleep'; Arguments = [string[]]@('120'); WorkingDirectory = '$TestDrive' }
Set-Content -LiteralPath '$childPidFile' -Value (Start-SourcePlatform -Command `$command -LogDir '$logDir')
Start-Sleep -Seconds 120
"@
            $perl = (Get-Command perl -CommandType Application | Select-Object -First 1).Source
            $info = [System.Diagnostics.ProcessStartInfo]::new($perl)
            if ($WithoutSetsid) {
                # sh and sleep only: the launcher finds no setsid, as on macOS.
                $bin = Join-Path $TestDrive "bin-$Signal"
                $null = New-Item -ItemType Directory -Path $bin
                foreach ($tool in 'sh', 'sleep') {
                    $null = New-Item -ItemType SymbolicLink -Path (Join-Path $bin $tool) -Target (Get-Command $tool -CommandType Application | Select-Object -First 1).Source
                }
                $info.Environment['PATH'] = $bin
            }
            # setpgrp then exec: the launcher is the leader of its own process group (its pid), as a terminal's foreground job is.
            foreach ($argument in '-e', 'setpgrp(0, 0); exec @ARGV', (Get-Process -Id $PID).Path, '-NoProfile', '-File', $launcher) {
                $info.ArgumentList.Add($argument)
            }
            $info.WorkingDirectory = $TestDrive
            $info.UseShellExecute = $false
            $outer = [System.Diagnostics.Process]::Start($info)
            $childId = 0
            try {
                Wait-Until { (Test-Path -LiteralPath $childPidFile) -and ((Get-Content -LiteralPath $childPidFile -Raw).Trim() -match '^\d+$') } | Should -BeTrue
                $childId = [int](Get-Content -LiteralPath $childPidFile -Raw).Trim()
                $groupId = $outer.Id

                & $perl -e 'kill($ARGV[0], -$ARGV[1])' $Signal $groupId

                # The signal did reach the group: the launcher is gone. The platform must not be.
                Wait-Until { Test-ProcessGone $groupId } | Should -BeTrue
                Start-Sleep -Seconds 1
                Test-ProcessGone $childId | Should -BeFalse

                # stop.ps1 still stops it, by the recorded pid.
                Stop-SourcePlatform -LogDir $logDir | Should -BeTrue
                Wait-Until { Test-ProcessGone $childId } | Should -BeTrue
            }
            finally {
                if ($childId -gt 0) { Get-Process -Id $childId -ErrorAction Ignore | Stop-Process -Force -ErrorAction Ignore }
                if (-not $outer.HasExited) { $outer.Kill($true) }
            }
        }

        It 'returns $false and removes the file when the recorded process no longer exists' {
            $logDir = Join-Path $TestDrive 'logs-gone'
            $null = New-Item -ItemType Directory -Path $logDir
            $process = Start-SleepingPwsh
            Write-PidFile -LogDir $logDir -Process $process
            $process.Kill()
            $process.WaitForExit()

            Stop-SourcePlatform -LogDir $logDir | Should -BeFalse

            Join-Path $logDir 'platform.pid' | Should -Not -Exist
        }

        It 'returns $false when there is no pid file' {
            Stop-SourcePlatform -LogDir (Join-Path $TestDrive 'no-logs') | Should -BeFalse
        }

        It 'removes a pid file it cannot read, and kills nothing' {
            $logDir = Join-Path $TestDrive 'logs-junk'
            $null = New-Item -ItemType Directory -Path $logDir
            Set-Content -LiteralPath (Join-Path $logDir 'platform.pid') -Value 'not a pid'

            Stop-SourcePlatform -LogDir $logDir | Should -BeFalse

            Join-Path $logDir 'platform.pid' | Should -Not -Exist
        }

        It 'does not kill a live process whose start time differs from the recorded one (a reused pid)' {
            $logDir = Join-Path $TestDrive 'logs-reused'
            $process = Start-SleepingPwsh
            try {
                Write-PidFile -LogDir $logDir -Process $process -StartTicksOffset (-[TimeSpan]::FromHours(1).Ticks)

                Stop-SourcePlatform -LogDir $logDir | Should -BeFalse

                $process.HasExited | Should -BeFalse
                Join-Path $logDir 'platform.pid' | Should -Not -Exist
            }
            finally {
                $process.Kill($true)
            }
        }

        It 'stops the whole tree: a launcher and the child it started (dotnet run and the platform)' {
            $logDir = Join-Path $TestDrive 'logs-tree'
            $childPidFile = Join-Path $TestDrive 'child.pid'
            $parent = Start-SleepingPwsh -ChildPidFile $childPidFile
            $childId = 0
            try {
                Wait-Until { (Test-Path -LiteralPath $childPidFile) -and ((Get-Content -LiteralPath $childPidFile -Raw).Trim() -match '^\d+$') } | Should -BeTrue
                $childId = [int](Get-Content -LiteralPath $childPidFile -Raw).Trim()
                Test-ProcessGone $childId | Should -BeFalse
                Write-PidFile -LogDir $logDir -Process $parent

                Stop-SourcePlatform -LogDir $logDir | Should -BeTrue

                Wait-Until { (Test-ProcessGone $parent.Id) -and (Test-ProcessGone $childId) } | Should -BeTrue
            }
            finally {
                if (-not $parent.HasExited) { $parent.Kill($true) }
                if ($childId -gt 0) { Get-Process -Id $childId -ErrorAction Ignore | Stop-Process -Force -ErrorAction Ignore }
            }
        }
    }
}

Describe 'Elasticsearch CA fingerprint' -Tag 'Unit' {
    BeforeEach {
        $global:SourceModeTestFingerprint = ('ab' * 32) + "`n"
        Mock Invoke-DockerCompose {
            if ($args -contains 'cp') {
                Set-Content -LiteralPath $args[-1] -Value $global:SourceModeTestFingerprint -NoNewline
            }
            $global:LASTEXITCODE = 0
        }
    }

    AfterAll {
        Remove-Variable -Name SourceModeTestFingerprint -Scope Global -ErrorAction Ignore
    }

    It 'brings es-setup up, waits for it, and copies the fingerprint out of it' {
        Get-ElasticsearchCaFingerprint | Should -BeExactly ('ab' * 32)

        Should -Invoke Invoke-DockerCompose -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'up -d --wait es-setup' }
        Should -Invoke Invoke-DockerCompose -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'cp' -and $args[1] -eq 'es-setup:/usr/share/elasticsearch/config/certs/ca/ca.fingerprint' }
    }

    It 'rejects a file that is not a SHA-256 in hex' {
        $global:SourceModeTestFingerprint = 'garbage'

        { Get-ElasticsearchCaFingerprint } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*garbage*'
    }

    It 'fails when Compose cannot bring es-setup up' {
        Mock Invoke-DockerCompose { $global:LASTEXITCODE = 1 }

        { Get-ElasticsearchCaFingerprint } | Should -Throw -ExceptionType ([System.InvalidOperationException]) -ExpectedMessage '*es-setup*'
    }
}
