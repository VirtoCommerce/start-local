# 🚀 Try Virtocommerce solution locally

Run Virtocommerce backend, Virtocommerce frontend, database server, Redis, Elasticsearch and Kibana on your local machine using a simple powershell script. This setup uses [Docker](https://www.docker.com/) behind the scenes to install and run the services.

> [!IMPORTANT]  
> This script is for local testing only. Do not use it in production!
> !TODO! For production installations refer to the official documentation for [Elasticsearch](https://www.elastic.co/downloads/elasticsearch) and [Kibana](https://www.elastic.co/downloads/kibana).


## 💻 System requirements

- ~6 GB of available disk space
- [.NET SDK](https://dotnet.microsoft.com/en-us/download/dotnet): Required only for `vc-build` installation
- [vc-build](https://github.com/VirtoCommerce/vc-build): command to install `dotnet tool install VirtoCommerce.GlobalTool -g`
- [Docker](https://www.docker.com/): On non-Windows systems docker supposed to be configure to do NOT require `sudo` to run `docker *` commands
- Works on Windows
- !TODO! On Linux and MacOS it works using pwsh [Install PowerShell on Linux](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux), [Installing PowerShell on macOS](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos)

## 🏃‍♀️‍➡️ Getting started

### Setup

Run the script to create a local folder `VirtoLocal` containing all necessary files:

```pwsh
!TODO!Invoke-Expression (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/AndrewEhlo/test-local-run/refs/heads/main/VirtoLocal_create_local_files.ps1" -UseBasicParsing).Content
```
This script creates an `VirtoLocal` folder containing:
- `docker-compose.yml`: Docker Compose configuration for VirtoCommerce solution
- `backend` folder: Dockerfile and script(s) for the backend
- `frontend` folder: Dockerfile and config file(s) for the frontend
- `scripts` folder: Scripts in the build solution process
- `build-VC-solution.ps1`: Script to build docker images for backend and frontend
- `start-VC-solution.ps1`: Script to start a solution using built by `build-VC-solution.ps1` script
- `stop-VC-solution.ps1`: Script stops VC solution but does NOT remove the volumes associated with the docker containers
- `remove-VC-solution.ps1`: Script removes docker volumes associated with the containers, removes backend and frontend docker images from local docker storage

### Select the versions to install

The versions of the PGSQL and Elastic stack in the solution, and ports used by the components are controlled by the variables in `.env` file. The default values are:
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

## 🐳 Start and stop the services

The first step of the setup is to run a `build-VC-solution.ps1` script. 
The script has two parameters controlling the versions of the VirtoCommerce components:
- `vcModulesBundle`: Parameter controlls which stable bundle to use for the backend. [More info](https://github.com/VirtoCommerce/vc-modules/tree/master/bundles). Ex.: `latest` or`v10`
- `frontendRelease`: Parameter controlls the frontend release to use. Ex.: `latest` or `2.27.0`. [More info](https://github.com/VirtoCommerce/vc-frontend/releases)

The second step is to run a `start-VC-solution.ps1` script. The docker compose file is used to run the solution including VirtoCommers backend and frontend, PostgresSQL, Elastic Search and Kibana. [Docker Compose](https://docs.docker.com/reference/cli/docker/compose/).

To stop the container the `stop-VC-solution.ps1` script should be used. It stops the containers, but remains the volumes assoiciates with the containers, affectivly saving all data in the database and files in saved to persistente volumes.


## 🗑️ Uninstallation

If you need to stop the solution and remove all the data the script `remove-VC-solution.ps1` can be used. It stops the containers, removes data in the persistent volumes and removes `vc-platform:local-latest` and `vc-frontend:local-latest` docker images.

> [!WARNING]  
> This erases all data permanently.

> [!WARNING]  
> The PostgresSQL, Elastic Search and Kibana images will NOT be removed by the script.
