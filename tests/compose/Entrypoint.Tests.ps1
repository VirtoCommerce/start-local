# Runs backend/entrypoint.sh in a throwaway alpine container, with the script piped through stdin: no bind mount,
# so Docker Desktop File Sharing is not involved (FC §14). Needs a Docker daemon.
BeforeDiscovery {
    . "$PSScriptRoot/../../scripts/_init.ps1"

    $script:hasDaemon = Test-DockerRunning
}

BeforeAll {
    . "$PSScriptRoot/../../scripts/_init.ps1"
    . "$PSScriptRoot/../support/TestHelpers.ps1"

    function script:Invoke-EntrypointPrintingEnvironment {
        # The environment `env` prints when the entrypoint runs it. $Setup runs first in the container.
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Setup,
            [string[]]$DockerArguments = @()
        )

        $entrypoint = (Get-Content -LiteralPath (Join-Path (Get-TestRepositoryRoot) 'backend/entrypoint.sh') -Raw) -replace "`r`n", "`n"
        $command = "$Setup cat > /e.sh && sh /e.sh env"
        $output = $entrypoint | & docker run --rm -i @DockerArguments alpine sh -c $command 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw [System.InvalidOperationException]::new("docker run failed with exit code ${LASTEXITCODE}: $output")
        }
        [string[]]@($output)
    }
}

Describe 'backend/entrypoint.sh' -Tag 'Compose' -Skip:(-not $script:hasDaemon) {
    It 'exports the CA fingerprint for the search provider when the file exists' {
        $environment = Invoke-EntrypointPrintingEnvironment `
            -Setup 'mkdir -p /certs/ca && echo ab12 > /certs/ca/ca.fingerprint &&' `
            -DockerArguments '-e', 'SEARCH_PROVIDER=ElasticSearch8'

        $environment | Should -Contain 'Search__ElasticSearch8__CertificateFingerprint=ab12'
    }

    It 'strips whitespace from the fingerprint' {
        $environment = Invoke-EntrypointPrintingEnvironment `
            -Setup 'mkdir -p /certs/ca && printf "  ab12\r\n" > /certs/ca/ca.fingerprint &&' `
            -DockerArguments '-e', 'SEARCH_PROVIDER=ElasticSearch9'

        $environment | Should -Contain 'Search__ElasticSearch9__CertificateFingerprint=ab12'
    }

    It 'exports nothing without the file' {
        $environment = Invoke-EntrypointPrintingEnvironment -Setup '' -DockerArguments '-e', 'SEARCH_PROVIDER=ElasticSearch8'

        @($environment | Where-Object { $_ -like '*CertificateFingerprint*' }) | Should -BeNullOrEmpty
    }

    It 'exports nothing without SEARCH_PROVIDER' {
        $environment = Invoke-EntrypointPrintingEnvironment -Setup 'mkdir -p /certs/ca && echo ab12 > /certs/ca/ca.fingerprint &&'

        @($environment | Where-Object { $_ -like '*CertificateFingerprint*' }) | Should -BeNullOrEmpty
    }
}
