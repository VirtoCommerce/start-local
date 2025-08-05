# 🚀 Try the Virtocommerce solution locally

Run the Virtocommerce backend, frontend, database server, Redis Elasticsearch, and Kibana on your local machine with a simple PowerShell script. This setup uses Docker behind the scenes to install and run the services.

> [!IMPORTANT]  
> This script is for local testing only. Do not use it in production!
> !TODO! For production installations refer to the official documentation for [Elasticsearch](https://www.elastic.co/downloads/elasticsearch) and [Kibana](https://www.elastic.co/downloads/kibana).


## 💻 System Requirements

- ~5 GB of available disk space
- [.NET SDK](https://dotnet.microsoft.com/en-us/download/dotnet): Required only for the `vc-build` installation
- [vc-build](https://github.com/VirtoCommerce/vc-build): Command to install `dotnet tool install VirtoCommerce.GlobalTool -g`
- [Docker](https://www.docker.com/): On non-Windows systems Docker is supposed to be configured so that it does not require sudo to run Docker commands
- Works on Windows
- On Linux and MacOS it works using pwsh [Install PowerShell on Linux](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux), [Installing PowerShell on macOS](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos)

## 🏃‍♀️‍➡️ Getting started

### Setup

Run the script to create a local folder `VirtoLocal` containing all the necessary files:

```pwsh
Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/dev/VirtoLocal_create_local_files.ps1" -UseBasicParsing).Content
```
Created files:
- `docker-compose.yml`: Docker Compose configuration for VirtoCommerce solution
- `backend` folder: Dockerfile and script(s) for the backend
- `frontend` folder: Dockerfile and config file(s) for the frontend
- `scripts` folder: Scripts in the build solution process
- `build-VC-solution.ps1`: Script to build docker images for backend and frontend
- `start-VC-solution.ps1`: Script to start a solution using built by `build-VC-solution.ps1` script
- `stop-VC-solution.ps1`: Script stops VC solution but does NOT remove the volumes associated with the docker containers
- `remove-VC-solution.ps1`: Script removes docker volumes associated with the containers, removes backend and frontend docker images from local docker storage

The first step of the setup process is to run a `build-VC-solution.ps1` script. 
This script has the only parameter that control the versions of the VirtoCommerce components:
- `vcSolutionVersion`: This parameter accepts `latest-stable` or `edge` values. The `latest-stable` value installs the latest stable [bundle](https://github.com/VirtoCommerce/vc-modules/tree/master/bundles) of the backend with a compatible version of the frontend. The `edge` value installs the latest available releases of backend and frontend.

The second step is to run the `start-VC-solution.ps1` script. The Docker Compose file runs the solution, including the VirtoCommerce backend and frontend, PostgreSQL, Elasticsearch, and Kibana. [Docker Compose](https://docs.docker.com/reference/cli/docker/compose/).

To stop the containers, use the `stop-VC-solution.ps1` script. This script stops the containers but retains the volumes associated with them, effectively saving all database data and file data to persistent volumes.

### Select the versions to install

The versions of the PGSQL and Elastic Stack components in the solution and the ports they use are controlled by the variables in the .env file. The default values are:
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
This settings can be setup manually by editing `.env` file.

> [!IMPORTANT]
> After changing the `.env` file, restart the services using `stop-VC-solution.ps1` and `start-VC-solution.ps1`


## 🗑️ Uninstallation

If you need to stop the solution and remove all the data, use the script `remove-VC-solution.ps1`. This script stops the containers, removes the data in the persistent volumes, and deletes the `vc-platform:local-latest` and `vc-frontend:local-latest` Docker images.

> [!WARNING]  
> This erases all data permanently.

> [!WARNING]  
> The PostgresSQL, Redis, Elastic Search and Kibana images will NOT be removed by the script.
