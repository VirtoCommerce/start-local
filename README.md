# 🚀 Run Virto Commerce Locally with Docker

Set up a complete Virto Commerce environment on your local machine with a single PowerShell script. The solution includes:
- Virto Commerce Backend (platform)
- Virto Commerce Frontend (storefront)
- Database (PostgreSQL, MySQL, or SQL Server)
- Redis
- Elasticsearch
- Kibana

Everything is configured in one `.env` file. The stack is served over HTTPS by default, and the platform and its modules can run from your own source checkouts instead of Docker.

> [!IMPORTANT]
> This setup is for local development and testing only. Not for production use!
>
> - **Ports bind to `127.0.0.1`** (`BIND_ADDRESS`), so the stack is reachable from your machine only. Set `BIND_ADDRESS=0.0.0.0` in `.env` to reach it from other machines, and only on a network you trust.
> - **In HTTPS mode (the default)** Elasticsearch and Kibana run with security on and TLS from a local setup CA, and the passwords come from `.env`.
> - **In HTTP mode** (`-allowInsecureHttp`, and every folder migrated from 1.x) Elasticsearch and Kibana run with security features disabled (`xpack.security.enabled=false`, TLS off). There is no authentication on the search cluster: anyone who can reach the published ports can read or modify the indexes. **Do not expose these ports beyond your local machine.**
>
> For production deployments, enable security and consult the official documentation for [Elasticsearch](https://www.elastic.co/guide/en/elasticsearch/reference/current/secure-cluster.html) and [Kibana](https://www.elastic.co/guide/en/kibana/current/using-kibana-with-security.html).

## 💻 System Requirements
- ~5 GB available disk space
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) on Windows, Linux and macOS (the scripts require it)
- [Docker](https://www.docker.com/) with Docker Compose **2.18.0 or later** (On Linux/macOS, configure Docker to run without sudo)
- [.NET SDK](https://dotnet.microsoft.com/download) (required for `vc-build` and for the HTTPS development certificate)
- [vc-build tool](https://github.com/VirtoCommerce/vc-build) (the installer installs or updates it: `dotnet tool update --global VirtoCommerce.GlobalTool`)

### Network access

The installer and the build download from these hosts. Add them to a proxy or firewall allowlist if you use one:

| Host | Used for |
|------|----------|
| `api.github.com` | the installer asks for the latest release |
| `github.com` | the release installer and the payload archive |
| `codeload.github.com` | the payload archive |
| `release-assets.githubusercontent.com` | the release installer asset |
| `raw.githubusercontent.com` | `build.ps1`: the module bundles (`bundles/stable.json`, `bundles/<name>/package.json`) |

`build.ps1` also reaches the hosts that `vc-build` downloads from.

## 🏃‍♀️ Getting Started

### Install

Run this command in the folder where `VirtoLocal` should be created:

```pwsh
Invoke-WebRequest https://github.com/VirtoCommerce/start-local/releases/latest/download/install.ps1 -OutFile install.ps1; ./install.ps1
```

`install.ps1` downloads the latest release, copies its files into `VirtoLocal`, creates `.env`, asks what it needs, builds the images and starts the stack. The installer that runs always matches the files it installs.

Re-run the installer at any time to update the folder (`./install.ps1` from the folder's parent, or with `-targetFolder`; never from inside the folder) to the latest release. It overwrites scripts and compose files, and never overwrites `.env`: existing values and generated passwords are kept.

Run it unattended with the parameters below and `-nonInteractive`:

```pwsh
./install.ps1 -nonInteractive -dbProvider postgres -releaseChannel stable
```

The old one-liner (`VirtoLocal_create_local_files.ps1` from `dev`) still works: it forwards to the latest release.

### Installer parameters

Parameters that persist are saved to `.env` (or to `COMPOSE_FILE`), so later runs keep them. Every parameter is optional.

| Parameter | Installer | build | start | remove | Persists to |
|-----------|:-:|:-:|:-:|:-:|-------------|
| `-targetFolder` / `-solutionFolder` (default `VirtoLocal` / the script's folder) | ✓ | ✓ | ✓ | ✓ | (the folder) |
| `-branch <ref>` | ✓ | | | | `START_LOCAL_REF` |
| `-dbProvider postgres\|mysql\|sqlserver` | ✓ | | ✓ | | `COMPOSE_FILE` |
| `-releaseChannel`, `-customPackagesJson`, `-customFrontendUrl` | ✓ | ✓ | | | `RELEASE_CHANNEL`, `CUSTOM_PACKAGES_JSON`, `CUSTOM_FRONTEND_URL` |
| `-allowInsecureHttp` | ✓ | | ✓ | | `COMPOSE_FILE` (no `.https` overlays) |
| `-skipPlatform`, `-skipFrontend`, `-skipElasticsearch`, `-skipKibana`, `-skipRedis` | ✓ | | ✓ | | `COMPOSE_FILE`; `SKIP_PLATFORM` for a platform run from source |
| `-skipSampleData [bool]` | ✓ | ✓ | ✓ | | per run |
| `-nonInteractive` (also automatic when stdin is redirected or `CI=true`) | ✓ | ✓ | ✓ | ✓ | per run |
| `-keepData` | | | | ✓ | per run |
| `-elasticsearchVersion` (obsolete) | ✓ | | | | set `STACK_VERSION` in `.env` |
| `-vcSolutionVersion` (obsolete) | ✓ | ✓ | | | use `-releaseChannel` |

Undo a persisted switch with `-<switch>:$false`, for example `./start.ps1 -skipKibana:$false`.

### Database Provider Selection

The installer asks for a database provider unless you pass `-dbProvider`:

| Provider   | Default Version | Default Port |
|------------|-----------------|--------------|
| PostgreSQL | 18.3            | 5432         |
| MySQL      | 9.3             | 3306         |
| SQL Server | 2022-latest     | 1433         |

#### Switching Database Providers

To switch providers after the initial setup, run `./stop.ps1` (if the stack is running), then `./start.ps1 -dbProvider mysql` (or `postgres`, `sqlserver`). The provider is read from the database file listed in `COMPOSE_FILE`; there is no `DB_PROVIDER` key.

Each provider stores its data in a separate Docker volume. Switching providers does **not** remove the previous provider's data, and it is still there when you switch back. Only a full `./remove.ps1` removes all volumes.

### Release channels

`RELEASE_CHANNEL` (or `-releaseChannel`) picks what `build.ps1` installs. Learn more about the release strategy by [following this link](https://docs.virtocommerce.org/platform/developer-guide/Updating-Virto-Commerce-Based-Project/release-strategy-overview/).
- `stable`: the latest stable backend bundle with its compatible storefront
- `stable:<N>`: stable bundle number `<N>`
- `edge`: the newest backend and storefront releases
- `custom`: your own backend package manifest. `CUSTOM_PACKAGES_JSON` is a local `package.json` path or an `http(s)://` URL (a relative path is saved as an absolute one). `CUSTOM_FRONTEND_URL` is an optional direct URL of a storefront ZIP; when it is empty, the latest `vc-frontend` GitHub release is used.

```pwsh
./install.ps1 -releaseChannel custom -customPackagesJson ./my-packages.json
./build.ps1 -releaseChannel custom -customPackagesJson https://example.com/my-bundle/package.json -customFrontendUrl https://example.com/my-frontend.zip
```

### Sample Data Installation

Sample data (catalogs, products, and so on) is installed when you build through the installer or `build.ps1`; pass `-skipSampleData $true` to skip it. A direct `./start.ps1` skips sample data by default, because `start` mostly restarts an existing install; pass `-skipSampleData $false` to install it on a start.

### Created Files and Folders

```
VirtoLocal/
├── .env                  # the configuration (created from .env.example)
├── docker-compose*.yml   # the compose file set; COMPOSE_FILE lists the files in use
├── backend/ frontend/    # Dockerfiles and nginx templates
├── scripts/              # helpers the scripts load
├── logs/                 # log and pid file of a platform run from source
├── install.ps1           # the installer; re-run it from the parent folder (or with -targetFolder) to update
└── build.ps1 start.ps1 stop.ps1 remove.ps1
```

- `build.ps1` builds the platform and storefront images, and exports the HTTPS development certificate.
- `start.ps1` starts the stack, waits for the platform, and prints the URLs.
- `stop.ps1` stops the stack and keeps the data. The services restart with Docker (`restart: unless-stopped`) until you stop them.
- `remove.ps1` removes the stack (see Uninstallation below).

### Endpoints
After running the script (HTTPS mode, the default):
* **Virto Commerce Frontend**: https://localhost (`FRONTEND_PORT=443`)
* **Virto Commerce Backend**: https://localhost:8090 (`PLATFORM_PORT`)

In HTTP mode (`-allowInsecureHttp`) the same services run at http://localhost (`FRONTEND_PORT=80`) and http://localhost:8090. `start.ps1` prints the actual URLs at the end of every run.

### Initial Configuration
1. Open the **Virto Commerce Backend** and sign in using the default credentials:
    * Username: **admin**
    * Password: **store**
1. You will be prompted to change the password upon first login.
1. Review or install the sample data set to populate the system with example products and catalogs.
1. Navigate to the Search Index section and ensure that all indexes are built successfully.
1. Open the Virto Commerce Frontend to view and explore the sample data.

Non-interactive runs (`-nonInteractive`, redirected stdin, or `CI=true`) do not use the default password: they apply `ADMIN_PASSWORD` from `.env` to the `admin` user on every start (and generate and save one when the key is empty), without a change-password prompt. Interactive runs never touch the admin password.

Please take a look at [Virto Commerce Documentation](https://docs.virtocommerce.org/) for additional configuration and customisation guidance.

## ⚙️ Configuration: the `.env` file

`.env` is the only configuration. Edit it, then run `./start.ps1` again. Every script also keeps `COMPOSE_FILE` in its canonical order. A plain `docker compose up` inside the folder sees the same `.env`.

| Key | Meaning |
|-----|---------|
| `START_LOCAL_LAYOUT` | `2`; maintained by the scripts. A folder without it is treated as an old 1.x folder and migrated |
| `START_LOCAL_REF` | the release tag or branch of the installed files |
| `COMPOSE_PATH_SEPARATOR` | `;`; the same `.env` works on Windows and Linux |
| `COMPOSE_FILE` | the compose files that make up the stack (see below) |
| `VOLUME_PREFIX` | prefix of the Docker volume names; empty means the folder name (`virto` for migrated folders) |
| `BIND_ADDRESS` | interface the ports bind to; `127.0.0.1` by default, `0.0.0.0` allows other machines |
| `RELEASE_CHANNEL`, `CUSTOM_PACKAGES_JSON`, `CUSTOM_FRONTEND_URL` | what `build.ps1` installs (see [Release channels](#release-channels)) |
| `SEARCH_PROVIDER` | the platform's search provider module; `ElasticSearch8` by default |
| `ADMIN_PASSWORD` | applied by non-interactive runs |
| `PLATFORM_SOURCE_PATH`, `MODULE_SOURCE_PATHS`, `SKIP_PLATFORM` | run from source (see below); empty means Docker |
| `PGSQL_VERSION`, `MYSQL_VERSION`, `MSSQL_VERSION`, `STACK_VERSION` | image versions; `STACK_VERSION` is the Elasticsearch and Kibana version |
| `PGSQL_PORT`, `MYSQL_PORT`, `MSSQL_PORT`, `ES_PORT`, `KIBANA_PORT`, `REDIS_PORT`, `PLATFORM_PORT`, `FRONTEND_PORT` | published ports |
| `ES_MEM_LIMIT` | Elasticsearch memory limit; it sizes the heap itself |
| `DB_PASSWORD`, `REDIS_PASSWORD`, `ELASTIC_PASSWORD`, `KIBANA_PASSWORD` | generated at install when empty and **never rotated**; an existing database volume keeps the password it was created with |

`.env` rules: one `KEY=value` per line, with comments on their own lines. A value that `.env` cannot store unchanged (for example a password with `$`, `#`, quotes or a newline) is refused with a message naming the key, never written corrupted.

`FRONTEND_PORT` follows the mode: switching to HTTPS rewrites `80` to `443`, and switching to HTTP rewrites `443` to `80`. Any other value is yours and is never touched.

### `COMPOSE_FILE`

`COMPOSE_FILE` lists the stack: the database, the platform, Elasticsearch, Kibana, Redis, the storefront, plus small link files that wire two parts together and `.https` overlays. Pick parts with the `-skip*` switches and `-dbProvider`; do not hand-edit the link files and overlays, because every script run adds the missing ones and removes the ones that no longer apply. Your own override files stay listed after the built-in files, so you can add them by hand.

`docker-compose.es-limited.yml` is the one opt-in file: add it to `COMPOSE_FILE` to run Elasticsearch single-node, without memory locking (for hosts that cap kernel resource limits, such as cloud VMs and CI). It is safe over existing data.

### Writing `.env` before the first install

A wrapper (for example a cloud environment) can write `VirtoLocal/.env` before the first install. The installer keeps that file and fills only the keys left empty. For the file to count as a current one, it must set a non-empty `COMPOSE_FILE` (or `START_LOCAL_LAYOUT=2`); otherwise it is treated as a 1.x file and migrated.

## 🔒 HTTPS and trust

The stack is served over HTTPS by default:
- **Platform and storefront** use the ASP.NET Core development certificate. `build.ps1` exports it (`dotnet dev-certs`) and `start.ps1` delivers it to the containers through a Docker volume. Only the module source paths need Docker Desktop File Sharing.
- **Elasticsearch and Kibana** use their own certificates from a local setup CA, and the platform trusts Elasticsearch through the CA fingerprint.
- Use `-allowInsecureHttp` to get plain HTTP instead. The stack is never served over both at once.

**The scripts never install certificate trust.** Until you trust the development certificate, browsers and tools warn about it. `start.ps1` prints two routes, and you choose one:
1. `dotnet dev-certs https --trust`: Windows and macOS. On Ubuntu and Fedora (.NET 9 or later), first `export SSL_CERT_DIR="$HOME/.aspnet/dev-certs/trust:/usr/lib/ssl/certs"`.
2. Copy the exported certificate into the Linux system store:
   ```bash
   sudo cp backend/certs/localhost.pem /usr/local/share/ca-certificates/start-local-dev.crt
   sudo update-ca-certificates
   ```

The Elasticsearch setup CA is trusted the same way after you copy it out of the setup container: `docker compose cp es-setup:/usr/share/elasticsearch/config/certs/ca/ca.crt ./ca.crt`.

## 🧩 Run from source

The platform and the modules can run from your own checkouts. `start.ps1` only runs them; you build them yourself or from your IDE, and `start.ps1` fails fast when the build output is missing.

| Part | Docker (default) | From source |
|------|------------------|-------------|
| Platform | `PLATFORM_SOURCE_PATH` empty | `PLATFORM_SOURCE_PATH` is a vc-platform checkout or a prebuilt platform folder |
| Modules | installed by `build.ps1` from the release channel | `MODULE_SOURCE_PATHS`: module `*.Web` folders separated by `;`, **or** one whole `modules` folder, never both |
| Storefront | `docker-compose.frontend.yml` listed | not supported; run it with yarn and pass `-skipFrontend` |
| Database, Elasticsearch, Kibana, Redis | always Docker | not applicable |

- **Platform from source.** `start.ps1` writes the platform settings (the same values the Docker platform gets) to `VirtoCommerce.Platform.Web.settings.json` in the platform's content root, then runs it in the background with `ASPNETCORE_ENVIRONMENT=Development`, writing `logs/platform.log` and `logs/platform.pid`. `stop.ps1` and `remove.ps1` stop it. It needs a .NET 10 platform and the content root as the working directory, which also applies to an IDE launch.
- **Platform skipped (`SKIP_PLATFORM=true` or `-skipPlatform`).** `start.ps1` prepares everything (settings file, module links, services), does not launch the platform, and prints the command to run from a debugger.
- **Modules.** With a platform from source, each `*.Web` folder is symlinked into `<platform>/modules/<module id>`, and a `modules` folder becomes the platform's modules folder. On Windows, creating symlinks needs Developer Mode or an elevated shell. With the Docker platform, `start.ps1` generates `docker-compose.platform-modules.yml` with bind mounts of the module folders over the installed modules.

## 🔄 Daily use

```pwsh
./start.ps1      # start the stack (re-run after editing .env)
./stop.ps1       # stop the stack, keep all data
./build.ps1      # rebuild the images for the current RELEASE_CHANNEL
```

After changing `.env`, run `./start.ps1` again.

## ⬆️ Upgrading from 1.x

Run the new installer over the existing folder (`./install.ps1` in its parent folder, or the one-liner above). It copies the new files and **migrates `.env`**, keeping its values and passwords; no data is deleted. The migration:
- turns `DB_PROVIDER` into `COMPOSE_FILE`, and adds the keys that the new `.env` has;
- sets `VOLUME_PREFIX=virto`, so the existing `virto_*` volumes keep their names and your data stays attached;
- retags the existing `vc-platform:local-latest` and `vc-frontend:local-latest` images for this folder, so no rebuild is needed;
- removes the keys the layout no longer reads (`DB_PROVIDER`, `ES_CLUSTER_NAME`, `ES_LICENSE`) and writes `START_LOCAL_LAYOUT=2`.

Every script runs this migration first, so running `start.ps1` in an old folder migrates it too.

What changes for a migrated folder:
- **HTTP mode.** It keeps running over HTTP, so its URLs stay the same. Switch to HTTPS later with `./start.ps1 -allowInsecureHttp:$false`; `FRONTEND_PORT` moves from `80` to `443` if you had not changed it. Elasticsearch stays at the version in `STACK_VERSION` and keeps its data.
- **`BIND_ADDRESS=127.0.0.1`.** The published ports now bind to your machine only. To reach the stack from other machines again, set `BIND_ADDRESS=0.0.0.0` in `.env`.
- **Redis** is now a cache without a volume, and the platform uses it. The old `virto_redisdata` volume is left alone, and a full `./remove.ps1` deletes it.
- **The old scripts are guards.** `build-VC-solution.ps1`, `start-VC-solution.ps1`, `stop-VC-solution.ps1` and `remove-VC-solution.ps1` were renamed to `build.ps1`, `start.ps1`, `stop.ps1` and `remove.ps1`. The old names now only print that and stop.

> [!WARNING]
> An old installer run over an existing folder (the 1.x `VirtoLocal_create_local_files.ps1`) **regenerates the passwords in `.env`**, and an existing database volume no longer accepts them. Restore the passwords from a backup of the old `.env` before you start the stack, then run the new installer.

**Staying on the old layout.** The 1.x layout lives on the `release/1.0` branch (tag `v1.0.0`). To install it, download `VirtoLocal_create_local_files.ps1` from that branch and run it with `-branch release/1.0` (the old installer defaults to `dev`):

```pwsh
Invoke-WebRequest https://raw.githubusercontent.com/VirtoCommerce/start-local/refs/heads/release/1.0/VirtoLocal_create_local_files.ps1 -OutFile VirtoLocal_create_local_files.ps1; ./VirtoLocal_create_local_files.ps1 -branch release/1.0
```

The new `install.ps1` installs the new layout only; given a ref without `install.ps1`, such as `release/1.0`, it stops and prints this advice.

## 🛠️ Troubleshooting

### Clearing Docker builder cache

In some cases, a failed or interrupted build can leave stale layers in the Docker builder cache, causing subsequent `build-VC-solution.ps1` runs to fail or produce unexpected results (e.g., missing files, outdated dependencies, or errors that disappear after a fresh pull). If you suspect this, inspect and clear the cache, then rebuild.

Check overall Docker disk usage (images, containers, volumes, build cache):

```pwsh
docker system df
```

For a detailed breakdown of individual build cache entries and their sizes:

```pwsh
docker system df -v
```

Or list builder cache records directly:

```pwsh
docker builder du
```

Remove all build cache:

```pwsh
docker builder prune -af
```

To reclaim space from unused images, containers, networks, **and** build cache in one go:

```pwsh
docker system prune -af
```

> [!WARNING]
> These commands remove cache/data on the host globally, not just for this solution. Subsequent builds of other projects will be slower until their caches are repopulated, and `docker system prune` will also delete any stopped containers and dangling images from unrelated projects.

## 🗑️ Uninstallation

Run `./remove.ps1` from the solution folder (it asks to confirm; `-nonInteractive` does not ask):
- stops the containers, and the platform when it runs from source
- deletes the persistent volumes (`<VOLUME_PREFIX>_*`) with all their data
- removes the `vc-platform` and `vc-frontend` images of this folder
- removes the folder

`./remove.ps1 -keepData` removes the containers, network, images and every file in the folder except `.env`, and keeps the volumes. Run the installer over the folder again to restore the stack with its data.

`remove.ps1` refuses a folder that contains `.git` (a repository checkout); run it from an installed solution folder.

> [!WARNING]
> A full remove permanently destroys all data.

> [!WARNING]
> Database (PostgreSQL, MySQL, or SQL Server), Redis, Elasticsearch, and Kibana base images remain installed.

## 🧪 Advanced / Testing

`install.ps1` supports a `-branch` parameter that installs a branch or tag of the [start-local](https://github.com/VirtoCommerce/start-local) repository instead of the latest release. Use this when testing changes from a feature branch:

```pwsh
./install.ps1 -branch feature/my-test-branch
```

The ref is saved as `START_LOCAL_REF`. This parameter is intended for development and testing of the `start-local` scripts themselves.

Run the tests with `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit|Compose|All` (Pester 5).

## References
* [Home](https://virtocommerce.com)
* [Community](https://www.virtocommerce.org)
* [Documentation](https://docs.virtocommerce.org/)

## License

Copyright (c) Virto Solutions LTD.  All rights reserved.

Licensed under the Virto Commerce Open Software License (the "License"); you
may not use this file except in compliance with the License. You may
obtain a copy of the License at

http://virtocommerce.com/opensourcelicense

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied.
