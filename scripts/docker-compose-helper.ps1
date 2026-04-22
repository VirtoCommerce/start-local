$script:DockerComposeMode = $null

function Resolve-DockerComposeMode {
    # Prefer docker compose v2 (subcommand) - modern, ships with current Docker Desktop & Linux
    $null = & docker compose version 2>&1
    if ($LASTEXITCODE -eq 0) {
        return "v2"
    }
    # Fall back to legacy docker-compose v1 binary
    $null = & docker-compose --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        return "v1"
    }
    return $null
}

function Invoke-DockerCompose {
    if ($null -eq $script:DockerComposeMode) {
        $script:DockerComposeMode = Resolve-DockerComposeMode
        if ($null -eq $script:DockerComposeMode) {
            Write-Host "Error: neither 'docker compose' (v2) nor 'docker-compose' (v1) is available on PATH." -ForegroundColor Red
            exit 1
        }
    }
    $a = $args
    if ($script:DockerComposeMode -eq "v2") {
        & docker compose @a
    }
    else {
        & docker-compose @a
    }
}
