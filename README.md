# 🚀 Run Virtocommerce Locally with Docker

Set up a complete Virtocommerce environment on your local machine with a single PowerShell script. The solution includes:
- Virtocommerce backend
- Virtocommerce frontend
- PostgreSQL database
- Redis
- Elasticsearch
- Kibana

> [!IMPORTANT]  
> This setup is for local development and testing only. Not for production use!
> !TODO! For production deployments, consult the official documentation for [Elasticsearch](https://www.elastic.co/downloads/elasticsearch) and [Kibana](https://www.elastic.co/downloads/kibana).

## 💻 System Requirements

- ~5 GB available disk space
- [.NET SDK](https://dotnet.microsoft.com/download) (Required for `vc-build` installation)
- [vc-build tool](https://github.com/VirtoCommerce/vc-build) (Install with: `dotnet tool install VirtoCommerce.GlobalTool -g`)
- [Docker](https://www.docker.com/) (On Linux/MacOS, configure Docker to run without sudo)
- Compatible with Windows
- For Linux/MacOS: Requires PowerShell ([Linux install](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux), [macOS install](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos))

## 🏃‍♀️ Getting Started

### Initial Setup

Run this command to create a local `VirtoLocal` directory with all required files:

```pwsh
Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/dev/VirtoLocal_create_local_files.ps1" -UseBasicParsing).Content
```

Created files and folders:
- `docker-compose.yml`: Docker Compose configuration for VirtoCommerce solution
- `backend` folder: Dockerfile and script(s) for the backend
- `frontend` folder: Dockerfile and config file(s) for the frontend
- `scripts` folder: Scripts in the build solution process
- `build-VC-solution.ps1`: Script to build docker images for backend and frontend
- `start-VC-solution.ps1`: Script to start a solution using built by `build-VC-solution.ps1` script
- `stop-VC-solution.ps1`: Script stops VC solution but does NOT remove the volumes associated with the docker containers
- `remove-VC-solution.ps1`: Script removes docker volumes associated with the containers, removes backend and frontend docker images from local docker storage

Installation Steps
1. First run `build-VC-solution.ps1` with these version options:
- `vcSolutionVersion` parameter:
    - `latest-stable`: Installs the latest stable backend bundle with compatible frontend
    - `edge: Installs` the newest backend and frontend releases

2. Then run `start-VC-solution.ps1` to launch:
- Virtocommerce backend/frontend
- PostgreSQL
- Redis
- Elasticsearch
- Kibana

Use `stop-VC-solution.ps1` to pause containers while preserving your data.

### Version Configuration

Customize versions and ports in the `.env` file. Default settings:
```
PGSQL_VERSION=16.9
STACK_VERSION=8.18.0
PLATFORM_PORT=8090
ES_PORT=9200
KIBANA_PORT=5601
DB_PASSWORD=$(New-RandomPassword)
REDIS_PASSWORD=$(New-RandomPassword)
ELASTIC_PASSWORD=$(New-RandomPassword)
KIBANA_PASSWORD=$(New-RandomPassword)
PGSQL_PORT=5432
REDIS_PORT=6379
FRONTEND_PORT=80
```

> [!IMPORTANT]
> After changing the `.env` file, restart the services using `stop-VC-solution.ps1` and `start-VC-solution.ps1`


## 🗑️ Uninstallation

To fully uninstall and erase all data:
1. Run `remove-VC-solution.ps1`
- Stops containers
- Deletes persistent volumes
- Removes vc-platform:local-latest and vc-frontend:local-latest images

> [!WARNING]  
> This permanently destroys all data.

> [!WARNING]  
> PostgresSQL, Redis, Elasticsearch, and Kibana base images remain installed.
