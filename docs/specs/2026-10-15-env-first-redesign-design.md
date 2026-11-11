# start-local redesign: `.env`-first, release-pinned, HTTPS — design

**Status:** planned (2026-11-10, [implementation plan](../plans/2026-11-10-env-first-redesign.md)). From now on this document is historical: corrections go in a dated *Amendments* section, with the original text left intact.
**Decisions:** cited by ID from the [decision log](2026-10-15-redesign-decisions.md).
**Evidence:** cited by section from the [fact check](../research/2026-10-15-redesign-fact-check.md) (§N) and the [review follow-up](../research/2026-10-18-redesign-review-follow-up.md) (follow-up §N).

## 1. Problem

start-local works, but three things make it hard to automate and to extend:

1. **Configuration lives in parameters passed from script to script.** The unattended-setup draft (now stashed) needed 13 parameters on the installer, 11 on build and 7 on start. The same 5 start options were declared three times and forwarded create → build → start. Each new feature added another parameter in three places.
2. **The installer downloads 18 single files from the moving `dev` branch.** An installer saved earlier fetches whatever `dev` holds today, so the installer and the scripts can belong to different versions.
3. **Re-running the installer breaks existing data.** It regenerates every password, and an initialized database keeps the old one ([fact check §6](../research/2026-10-15-redesign-fact-check.md#6-re-running-todays-installer-breaks-db-volumes-live)).

There are further gaps:
- Everything serves plain HTTP, and every port binds to `0.0.0.0`.
- Redis runs but is never used (§18).
- The platform and modules can only run in Docker.
- The Elasticsearch settings fail on hosts that cap resource limits, such as CI runners and cloud VMs.
- Only the platform container restarts with Docker; the database and Elasticsearch don't.

## 2. Goals and non-goals

**Goals**
- `.env` is the single source of configuration. Scripts read it; they don't forward options to each other.
- Unattended setup in one call, for CI and Claude Code cloud routines.
- Installs are pinned to a release: the installer and the payload always come from the same version.
- HTTPS by default for the platform, storefront, Kibana and Elasticsearch.
- The platform and modules can each run from Docker or from source, and several source-run platforms can run side by side.
- Existing `VirtoLocal` folders keep working: they are migrated, not broken.

**Non-goals**
- Running the storefront from source. That is the developer's own setup (H8).
- Project-specific stacks, such as Marketplace or VirtoOZ. They differ only in modules and third-party services; their extra one or two processes (a frontend, a Python app) are the developer's to run.
- Installing certificate trust on the host (E5).
- Installing old releases through the new installer. `release/1.0` is reached with its own `VirtoLocal_create_local_files.ps1` (A10).
- Bash launchers. The scripts stay PowerShell 7 and cross-platform.

## 3. Approach

The model is borrowed from [asvishnyakov/virtocommerce](https://github.com/asvishnyakov/virtocommerce): one `.env` that Compose reads natively, scripts that do one job, and variation kept in data.

```
one-liner ─► bootstrap installer ─► resolve release ─► download one zip ─► run the payload's own installer
                                                                              │
             .env.example ─► .env (secrets filled once, empty keys asked once) ◄┘
                                │
             build / start / stop / remove ─── read .env, cd into the folder, run `docker compose`
                                │
                     COMPOSE_FILE = which compose files make up the stack
```

Options:

| # | Approach | Verdict |
|---|----------|---------|
| 1 | **`.env`-first: one `.env` that Compose reads natively, scripts that do one job, `COMPOSE_FILE` as the stack definition** | ✅ chosen |
| 2 | Keep the parameter chain and add `-nonInteractive` (V1) | ❌ fixes unattended runs but keeps the forwarding problem |

Rejected sub-decisions within option 1:
- **A branch per project, as the reference repo does.** Projects need no changes to start-local: they differ only in modules and third-party services, which the package manifest and `.env` already cover.
- **Compose profiles for optional services.** Rejected in H9 for one mechanism, `COMPOSE_FILE`.
- **HTTP and HTTPS as alternative copies of each compose file.** Every shared setting would be written twice; HTTPS is an overlay instead (E13).

## 4. Releases and installation

### 4.1 Branches and releases

- Development stays on `dev` (A4).
- `release/1.0` is cut from the current `dev` **before** the redesign merges. It carries the old layout. It is tagged `v1.0.0`, and its GitHub Release carries the current installer as its asset, since that layout has no `install.ps1`. A saved old installer reaches it with `-branch release/1.0`, and a new user downloads that branch's `VirtoLocal_create_local_files.ps1` and runs it (A5, A10). The raw URL form works for a branch name with a slash (§1).
- Without `-branch`, a saved old installer still downloads the files whose names survive (`docker-compose*.yml`, `scripts/`), then reaches the old build, start, stop and remove scripts, which on `dev` are only guards. Each guard throws an error that explains `release/1.0`, the new installer and migration (A5).
- Every release is a `release/X.Y` branch plus a `vX.Y.Z` tag and a GitHub Release (A1). The release attaches `install.ps1` as an asset (A8).
- The old README one-liner keeps working: `dev`'s `VirtoLocal_create_local_files.ps1` is a forwarder that downloads the latest release's `install.ps1` next to itself and calls `./install.ps1` with the same arguments (A9):

  ```powershell
  # Renamed to install.ps1 (start-local 2.0); forwards to the latest release.
  $installer = Join-Path $PSScriptRoot 'install.ps1'
  Invoke-WebRequest https://github.com/VirtoCommerce/start-local/releases/latest/download/install.ps1 -OutFile $installer
  & $installer @args
  ```
- The redesign ships as **v2.0.0**: the folder layout and the defaults change.

### 4.2 Bootstrap and delegation

The README one-liner downloads `github.com/VirtoCommerce/start-local/releases/latest/download/install.ps1` (A6).

That script runs as a **bootstrap**:

1. **Resolve the ref.** `-branch <ref>` is used if given. Otherwise the script calls `GET /repos/VirtoCommerce/start-local/releases/latest` (A7). That's one unauthenticated call, out of 60 per hour per IP (§3).
2. **Download one zip:** `github.com/VirtoCommerce/start-local/archive/refs/{tags|heads}/<ref>.zip` (A2). It goes to a temporary folder, and the top-level folder is named `start-local-<ref with / → ->` (§2).
3. **Delegate** to the `install.ps1` inside the zip, passing the bound parameters and the extracted path. Like nvm, **the installer that runs always matches its payload**. A payload without `install.ps1`, such as `release/1.0`, stops the bootstrap with a message that points to that ref's `VirtoLocal_create_local_files.ps1` (A10).

Network allowlists need these hosts for the bootstrap and the installer:
- `api.github.com`
- `github.com`
- `codeload.github.com`
- `release-assets.githubusercontent.com`

build also needs `raw.githubusercontent.com` for the vc-modules bundles (`bundles/stable.json`, `bundles/<name>/package.json`, B8), plus the hosts vc-build itself downloads from.

### 4.3 Installer

1. **Copy the payload** into `-targetFolder` (default `VirtoLocal`), overwriting scripts and compose files. It never touches `.env` (A3). Each old-named script in the folder (`build-`, `start-`, `stop-`, `remove-VC-solution.ps1`) is overwritten with its guard, which warns that the script is renamed and stops (A5).
2. **Create `.env`.** If there is no `.env`, copy `.env.example` (B2).
3. **Migrate** (§9).
4. **Fill secrets.** Each empty secret key gets a random value. Filled keys are never rotated, which fixes §6.
5. **Apply first-class parameters** to `.env` (§8).
6. **Ask for empty required keys** once, and save the answers (B3). In a non-interactive run (B4), a missing required value fails the run and names the key.
7. **Ask the per-run questions:** update vc-build, build now. Non-interactive runs take the defaults (C2).
8. **Run `build.ps1`**, passing only the per-run switches (`-skipSampleData`, `-nonInteractive`).

## 5. The solution folder

```
VirtoLocal/
├── .env                  # the configuration (from .env.example)
├── docker-compose*.yml   # the compose file set (§6)
├── backend/ frontend/    # Dockerfiles and nginx templates
├── scripts/              # helpers dot-sourced by the scripts
├── logs/                 # log and pid file of a platform run from source
├── install.ps1           # the installer; re-run to update (A3, A8)
└── build.ps1 start.ps1 stop.ps1 remove.ps1
```

### 5.1 `.env.example`

```ini
# --- Stack: maintained by the scripts ---
START_LOCAL_LAYOUT=2
START_LOCAL_REF=                 # release tag or branch of the installed payload
COMPOSE_PATH_SEPARATOR=;         # the same file works on Windows and Linux (§4)
COMPOSE_FILE=                    # empty: the installer asks for the DB provider and lists the defaults, docker-compose.https.yml included
VOLUME_PREFIX=                   # empty: the project (folder) name; migrated folders: virto
BIND_ADDRESS=127.0.0.1           # 0.0.0.0 allows access from other machines

# --- Solution ---
RELEASE_CHANNEL=                 # stable | stable:<N> | edge | custom; asked once when empty (B8)
CUSTOM_PACKAGES_JSON=            # custom: path or URL of the package manifest
CUSTOM_FRONTEND_URL=             # custom: storefront ZIP; empty = latest vc-frontend release
SEARCH_PROVIDER=ElasticSearch8   # ElasticSearch9 once that module is installed (D8)
ADMIN_PASSWORD=                  # non-interactive runs apply it, generating one when empty (C1)

# --- Run from source (empty = Docker) ---
PLATFORM_SOURCE_PATH=            # vc-platform checkout or prebuilt platform folder
MODULE_SOURCE_PATHS=             # ;-separated module *.Web folders, or one modules folder (H2)
SKIP_PLATFORM=                   # true: start prepares a source platform but doesn't launch it (B6)

# --- Versions, ports, limits ---
PGSQL_VERSION=18.3
PGSQL_PORT=5432
MYSQL_VERSION=9.3
MYSQL_PORT=3306
MSSQL_VERSION=2022-latest
MSSQL_PORT=1433
STACK_VERSION=9.5.5
ES_PORT=9200
KIBANA_PORT=5601
ES_MEM_LIMIT=1g
REDIS_PORT=6379
PLATFORM_PORT=8090
FRONTEND_PORT=443

# --- Secrets: filled at install when empty, never rotated ---
DB_PASSWORD=
REDIS_PASSWORD=
ELASTIC_PASSWORD=
KIBANA_PASSWORD=
```

- **The DB provider is inferred** from `COMPOSE_FILE` (C3). There is no `DB_PROVIDER` key.
- **There are no heap keys.** Elasticsearch sizes its heap from `ES_MEM_LIMIT` (D2, §7).
- **Fixed values stay in the compose files**: the Elasticsearch cluster name and license (C6).
- **Ports keep their keys across modes.** HTTP mode and HTTPS mode publish the same `PLATFORM_PORT`; only the scheme changes.

### 5.2 Precedence

1. Per-run switches: `-skipSampleData`, `-nonInteractive`, and the step questions.
2. First-class parameters, which are also saved into `.env`.
3. `.env`.
4. `.env.example` defaults, filled in by migration for keys an old `.env` lacks.

### 5.3 Derived settings

Docker services have no generated settings files (C4). Each compose file derives its service's settings from `.env` through interpolation: connection strings from `DB_PASSWORD`, `REDIS_PASSWORD` and the ports, public URLs from `PLATFORM_PORT`, the search settings from `SEARCH_PROVIDER` and `ELASTIC_PASSWORD`. `environment:` uses the list form, so a key can interpolate too (`- Search__${SEARCH_PROVIDER}__Key=${ELASTIC_PASSWORD}`; the form is verified). The CA fingerprint, known only at runtime, comes through the certificates volume instead (§10). The scheme comes from the HTTPS overlays (§6).

A plain `docker compose up` in the folder always sees the current `.env`.

A platform run from source gets the same settings in its per-folder settings file (§7.2), computed by one PowerShell function from the same `.env`. The compose YAML and that function both define the platform settings; a test keeps them equal (§12).

## 6. The compose file set

`COMPOSE_FILE` lists the files that make up the stack. Users and switches pick **feature files**. The scripts maintain **link files** (C5), which wire two features together, and **HTTPS overlays** (E13), every time they run.

Link files exist because Compose refuses a `depends_on` on an undefined service, even with `required: false` (live test, 2026-10-15). They also keep the feature files independent: a platform run from source simply has no platform file.

HTTPS overlays exist so that each service is defined once. A feature or link file holds the settings both modes share, with HTTP behavior. Its `.https.yml` overlay adds TLS and overrides `environment:` entries by key (follow-up §2). The base file's overlay is the mode switch (E13).

| File | Kind | Content |
|------|------|---------|
| `docker-compose.yml` | base, always listed | Network and the volume name template `${VOLUME_PREFIX:-${COMPOSE_PROJECT_NAME}}_*` (D3) |
| `docker-compose.https.yml` | overlay, listed in HTTPS mode | The certificates volume. Listing it is what puts the stack in HTTPS mode (E13) |
| `docker-compose.{postgres,mysql,sqlserver}.yml` | feature, exactly one | The `vc-db` service with a health check. The service name is the same for every provider |
| `docker-compose.platform.yml` | feature | `vc-platform-web`: image `vc-platform:${COMPOSE_PROJECT_NAME}-latest` (D3), settings interpolated from `.env` (§5.3), `depends_on: vc-db` (healthy), `VirtoCommerce__AllowInsecureHttp=true`. Left out when the platform runs from source or is skipped |
| `docker-compose.platform.https.yml` | overlay | Kestrel with the dev cert from the certificates volume; `VirtoCommerce__AllowInsecureHttp=false` |
| `docker-compose.platform-modules.yml` | link (script) | Bind mounts from `MODULE_SOURCE_PATHS` (H2); only when the platform runs in Docker and source modules are set |
| `docker-compose.elasticsearch.yml` | feature | `es` with security off, as today, but the cluster name and license fixed (C6) |
| `docker-compose.elasticsearch.https.yml` | overlay | The setup container (CA, certs, `ca/ca.fingerprint`, `kibana_system` password, health check); security and TLS on for `es` (E3, E11) |
| `docker-compose.kibana.yml` | feature | Kibana, as today |
| `docker-compose.kibana.https.yml` | overlay | Kibana serving TLS with a cert from the setup CA, and signing in to Elasticsearch over TLS (E9) |
| `docker-compose.frontend.yml` | feature | Storefront nginx, image `vc-frontend:${COMPOSE_PROJECT_NAME}-latest` (D3), the HTTP nginx template |
| `docker-compose.frontend.https.yml` | overlay | The HTTPS nginx template with the dev cert (E8) |
| `docker-compose.redis.yml` | feature, listed by default | Redis as a pure cache, with no volume (D6) |
| `docker-compose.platform-<feature>.yml` | link (script) | The platform's `depends_on` and settings for Elasticsearch and Redis (`ConnectionStrings__RedisConnectionString`, D6), and the storefront's `depends_on` for the platform |
| `docker-compose.platform-elasticsearch.https.yml` | overlay (script) | The HTTPS server URL, and the certificates volume mounted read-only, so the entrypoint finds `ca/ca.fingerprint` (E11) |
| `docker-compose.frontend-hostplatform.yml` | link (script) | `extra_hosts: host.docker.internal:host-gateway` when the storefront runs in Docker and the platform runs from source (H7) |
| `docker-compose.es-limited.yml` | feature, opt-in | `discovery.type=single-node`, `bootstrap.memory_lock=false`, `ulimits: !reset {}` (D1, H10). Safe on existing data (§5) |

Further rules:
- **Fixed container ports.** The platform and the storefront listen on one fixed container port in both modes. HTTPS or HTTP comes from the overlay (Kestrel URLs, the nginx template directory). Port mappings never change, and `!override` is never needed.
- **Autostart (D10).** Every long-running service has `restart: unless-stopped`; the Elasticsearch setup container has none.
- **Normalization.** Every script run rewrites `COMPOSE_FILE` in a canonical order. It adds the link files whose two features are present and removes those whose features aren't. When `docker-compose.https.yml` is listed, it lists the overlay of every listed file that has one; otherwise it removes them all. Skipping and re-adding a feature therefore never changes the mode. Unknown files, such as the user's own overrides, keep their position after the built-in files.

## 7. Docker or source

### 7.1 Choosing the mode

| Part | Docker | From source |
|------|--------|-------------|
| Platform | `PLATFORM_SOURCE_PATH` empty | `PLATFORM_SOURCE_PATH` is a vc-platform checkout (`dotnet run --no-build --project src/VirtoCommerce.Platform.Web`) or a prebuilt folder (`dotnet VirtoCommerce.Platform.Web.dll`); detected from the contents (H4) |
| Modules | from the package manifest (vc-build) | `MODULE_SOURCE_PATHS`: either `*.Web` folders (have `module.manifest`) or one whole `modules` folder, never both (H2) |
| Storefront | `docker-compose.frontend.yml` listed | not supported; the developer runs it with yarn (H8) |
| DB, Elasticsearch, Kibana, Redis | always Docker | not applicable |

The user or the IDE builds the source parts. start only runs them, and fails fast when the build output is missing (H6). With `-skipPlatform`, start prepares the platform without launching it, so the user can build it and run it from the debugger (B6).

### 7.2 Platform from source

- **Config (H5).** start writes the platform settings to `VirtoCommerce.Platform.Web.settings.json` in the platform's content root: `src/VirtoCommerce.Platform.Web/` of a checkout, or the prebuilt folder. .NET 10 loads that file after `appsettings.{env}.json` and reloads it on change (follow-up §1).
  - **Per folder.** Each platform folder has its own file, so two source-run platforms can run side by side, each with its own `.env` and stack (D3): for example VirtoOZ's management platform and a tenant platform.
  - **IDE runs** read the same file when the IDE's working directory is the content root.
  - **A clean checkout.** In a checkout, start adds the file name to `.git/info/exclude`.
  - **No user secrets.** The user-secrets store is one per machine and overrides the file, so the preflight warns when it defines a key start writes (§11).
  - start launches with `ASPNETCORE_ENVIRONMENT=Development`, from the content root as the working directory.
- **Modules (H2).** `MODULE_SOURCE_PATHS` holds one of two forms.
  - **`*.Web` folders:** each is symlinked as `<platform>/modules/<module id>`.
  - **One `modules` folder:** it becomes the platform's modules folder. `<platform>/modules` is a symlink to it, as in `VirtoCommerce.Platform/modules -> ../modules`. vc-build installs into it, so installed binaries and module source checkouts sit side by side. If `<platform>/modules` is a real directory with content, start refuses and names it.
  - start uses directory symlinks on every OS. The platform follows them on Linux (§13) and on Windows (the user's own setups, fact check *Amendments*). Creating one on Windows needs Developer Mode or an elevated shell; the preflight checks for it and names the fix (§11).
- **Process.** The platform runs in the background, writes `logs/platform.log`, and records `logs/platform.pid`. stop stops it. Docker's restart policy doesn't cover it (D10).
- **Skipped (B6).** With `SKIP_PLATFORM=true`, start writes the settings file and the module links, starts the Docker services, and prints the command to launch the platform. It doesn't launch it or wait for it.
- **Addresses.** The platform reaches Docker services through `localhost` and the published ports, which is why the Elasticsearch cert includes `localhost` (E3).

### 7.3 Platform in Docker with source modules

A `*.Web` entry becomes a bind mount at `/opt/virtocommerce/platform/modules/<module id>`, where the module id comes from `module.manifest`, replacing the installed copy of that module. This is the platform docs' "link the Module Web directory" workflow.

A `modules` folder is bind-mounted at `/opt/virtocommerce/platform/modules` itself, replacing the image's modules. build then has vc-build install the package manifest's modules into that folder instead of the image, through `vc-build install -DiscoveryPath <modules folder>` (follow-up *Amendments*).

## 8. Scripts and parameters

`.env` carries the configuration, so parameters are few and none is forwarded except per-run switches.

| Parameter | Installer | build | start | remove | Persists to |
|-----------|:-:|:-:|:-:|:-:|-------------|
| `-targetFolder` / `-solutionFolder` | ✓ | ✓ | ✓ | ✓ | (folder) |
| `-branch` | ✓ | | | | `START_LOCAL_REF` |
| `-dbProvider postgres\|mysql\|sqlserver` | ✓ | | ✓ | | `COMPOSE_FILE` |
| `-releaseChannel` (B8), `-customPackagesJson`, `-customFrontendUrl` | ✓ | ✓ | | | `RELEASE_CHANNEL`, `CUSTOM_*` |
| `-allowInsecureHttp` (B7) | ✓ | | ✓ | | `COMPOSE_FILE` (no `.https` overlays) |
| `-skipPlatform`, `-skipFrontend`, `-skipElasticsearch`, `-skipKibana`, `-skipRedis` (B6) | ✓ | | ✓ | | `COMPOSE_FILE`; `SKIP_PLATFORM` for a source platform |
| `-skipSampleData [bool]` | ✓ | ✓ | ✓ | | per run (C2) |
| `-nonInteractive` (B4; also automatic when stdin is redirected or `CI=true`) | ✓ | ✓ | ✓ | ✓ | per run |
| `-keepData` (F6) | | | | ✓ | per run |
| `-elasticsearchVersion` | `[Obsolete]` (B1) | | | | `STACK_VERSION` |
| `-vcSolutionVersion` | `[Obsolete]` (B1) | `[Obsolete]` | | | `RELEASE_CHANNEL` |

- **Grouping.** The skip switches sit under one comment section in each `param` block. They stay separate parameters (B6). Each is undone with `-<switch>:$false`.
- **One implementation.** Parameters that persist are applied by one helper (`scripts/options.ps1`), shared by the installer and start. PowerShell needs each script to declare its own `param` block, so declaring them in two scripts is the remaining duplication. Build keeps its existing solution parameters.
- **Obsolete parameters** use `[Obsolete("Use …")]`. PowerShell prints a warning only when the parameter is passed (§15). Their lifetime is open (B1).
- **Admin password (C1).** Interactive runs never touch it: `admin` / `store` with the platform's change-password prompt. Non-interactive runs apply `ADMIN_PASSWORD` on every start through `POST /api/platform/security/users/admin/resetpassword` with `forcePasswordChangeOnNextSignIn: false`, and first generate and save one when the key is empty. That includes migrated folders.
- **Optional files without a switch.** Capped limits are switched on by adding their file to `COMPOSE_FILE`. A cloud wrapper writes `VirtoLocal/.env` before the first install. B2 keeps that file, and the installer fills only the keys left empty.

### 8.1 Script flow

- **build:**
  1. When the platform runs in Docker: `vc-build install` for `RELEASE_CHANNEL` (B8) and the platform image. With a `modules` folder, vc-build installs the modules into that folder (§7.3).
  2. When the storefront is listed: the storefront image, from the bundle's `ThemeB2BVue` for `stable` and `stable:<N>`, or the latest vc-frontend release for `edge`.
  3. In HTTPS mode: export the dev cert (§10).
  4. Optionally, start.
- **start:**
  1. `cd` into the folder (required, §4).
  2. Migrate, then preflight checks (§11).
  3. Normalize `COMPOSE_FILE`.
  4. For a platform run from source: write its settings file from `.env` (§7.2), and place the module links. In HTTPS mode, bring up the Elasticsearch setup first and copy `ca/ca.fingerprint` from the certificates volume into the settings file (§10).
  5. `docker compose up -d`.
  6. Launch the platform from source, if configured and not skipped.
  7. Unless the platform is skipped: wait for it, then check the installed modules.
  8. Unless the platform is skipped: in non-interactive runs, apply the admin password (C1). Then sample data (per run).
  9. Print the URLs, plus trust instructions when the cert isn't trusted. A skipped platform gets the command to launch it instead of its URL.
- **stop:** `docker compose down`, plus stopping the source-run platform when its pid file exists.
- **remove (F6):**
  - Full: `down -v`, deleting volumes by `VOLUME_PREFIX` (as today, with the prefix in place of the fixed `virto_*` names), removing the images and the folder.
  - `-keepData`: `down` without `-v`, removing the images and every file in the folder except `.env`. Re-running the installer over the folder restores the stack with its data.

## 9. Migration

Every script runs `scripts/migrate.ps1` first. It is idempotent and keyed on `START_LOCAL_LAYOUT`, and a missing key means layout 1 (F1). Steps from layout 1 to 2:

1. **`DB_PROVIDER` becomes `COMPOSE_FILE`**, with the same provider, `COMPOSE_PATH_SEPARATOR=;`, Redis, and no HTTPS overlays. Migrated folders run in **HTTP mode**, so their URLs keep working (E1, E12).
2. **Missing keys are added** with `.env.example` defaults, plus `VOLUME_PREFIX=virto`, so existing volumes keep their names (D3). Existing values and passwords are kept. `STACK_VERSION` stays as it is: 8.18.0 needs no data migration (D7).
3. **Keys the layout no longer reads are removed:** `DB_PROVIDER` (after step 1), `ES_CLUSTER_NAME` and `ES_LICENSE` (C6).
4. **`BIND_ADDRESS=127.0.0.1`** applies to migrated folders too (D9). The upgrade output says how to restore `0.0.0.0`.
5. **Images are retagged**: `vc-platform:local-latest` and `vc-frontend:local-latest` get the per-project tag (`docker tag`), so no rebuild is needed (D3).
6. **`START_LOCAL_LAYOUT=2`** is written.

Redis now runs as a pure cache with no volume (D6). The old `virto_redisdata` volume is left alone, and a full remove deletes it. No step deletes data, so migration asks nothing (F2).

The installer replaces the payload files (§4.3). Migration changes only `.env` and Docker state.

## 10. HTTPS

| Endpoint | Cert | How |
|----------|------|-----|
| Platform | `dotnet dev-certs` (E4) | Exported as `localhost.pem` + `localhost.key`. Kestrel reads them through `Kestrel__Certificates__Default__{Path,KeyPath}` (verified, §11) |
| Storefront | The same export (E8) | nginx `ssl_certificate` / `ssl_certificate_key` in the HTTPS template. It proxies to the platform over HTTPS without verifying the internal hop |
| Elasticsearch | The setup CA (E3) | Elastic's official setup container cut to one node. TLS on HTTP and transport, security on |
| Kibana | The setup CA (E9) | `server.ssl.enabled`, with a `kibana` entry in `instances.yml` |

Further rules:
- **Delivery to containers (E10).** The dev-cert export goes into the named certificates volume with `docker cp`, through a short-lived helper container. Docker Desktop refuses bind mounts from paths outside its File Sharing list (§14), so only module source paths need File Sharing (§11).
- **The platform trusts Elasticsearch (E11)** through `Search:<Provider>:CertificateFingerprint`, a property both modules support (§9). The fingerprint never passes through `.env`:
  - The setup container writes the CA's SHA-256 to `ca/ca.fingerprint` in the certificates volume. The ES image has no `openssl`, so it uses `sed '/-----/d' ca.crt | base64 -d | sha256sum`, which gives the same value as `openssl x509 -fingerprint -sha256` (verified, ES 9.5.5).
  - The Docker platform's entrypoint, which start-local owns (D5), exports `Search__${SEARCH_PROVIDER}__CertificateFingerprint` from that file, then starts `dotnet`. A plain `docker compose up` therefore works end to end.
  - For a platform run from source, start copies the file from the volume into the platform's settings file.
  - The transport accepts the fingerprint in any case, with or without colons, and matches it against every certificate in the chain, the CA included (follow-up *Amendments*).
- **Search provider (D8).** `SEARCH_PROVIDER` in `.env`, default `ElasticSearch8`, which also works with Elasticsearch 9 servers. Neither bundle ships ES9 (§9).
- **Trust (E5).** The scripts never install it. When the dev cert is untrusted, start prints two routes: `dotnet dev-certs https --trust` (Windows, macOS; Ubuntu and Fedora with .NET 9+ and `SSL_CERT_DIR` set), or copying the export into the system store (`/usr/local/share/ca-certificates` + `update-ca-certificates`) (§11). The setup CA is printed with the same instructions.
- **HTTP mode (E1, E12).** `-allowInsecureHttp` removes every `.https.yml` overlay from `COMPOSE_FILE` (E13), which leaves today's behavior; the platform file keeps `VirtoCommerce:AllowInsecureHttp=true`. The stack is never served over both at once.

## 11. Preflight checks

These fail fast with a message that names the fix:

- **PowerShell 7 or later.**
- **Docker running, and Compose v2.18.0 or later** (D4; inferred minimum, §4).
- **Ports free**: the existing check, limited to the services in `COMPOSE_FILE`.
- **Docker Desktop file sharing** for each bind-mounted `MODULE_SOURCE_PATHS` entry: a probe `docker run --rm -v <path>:/x:ro` that reports `mounts denied` (§14).
- **`MODULE_SOURCE_PATHS` form**: `*.Web` folders or one `modules` folder, not a mix (H2).
- **Symlink rights on Windows**, when source modules or a source platform need links: Developer Mode or an elevated shell (§7.2).
- **Source-mode build output**: `VirtoCommerce.Platform.Web.dll` present, or the checkout already built (H6). Skipped when the platform is skipped (B6).
- **Required `.env` keys** in non-interactive runs (B3, B4).

Two checks only warn:
- **Shadowing user secrets**: the machine's `VirtoCommerce.Platform.Web` user-secrets store defines a key that the source platform's settings file sets (H5).
- Failures of the installed-modules check and of sample data are reported but don't stop the run, as today.

## 12. Testing

start-local has no tests or CI today. CI runs on GitHub-hosted runners (G1, follow-up §5).

- **Unit (Pester 5).** These cover the pure functions:
  - reading and writing `.env` with comments and order preserved;
  - filling secrets without ever rotating them;
  - `COMPOSE_FILE` normalization (links, HTTPS overlays) and provider inference, including that skipping and re-adding features never changes the HTTPS mode;
  - the settings-file function, checked against `docker compose config` for the platform service from the same `.env`, so the YAML and the function can't drift (§5.3);
  - each migration step, against real layout-1 `.env` fixtures;
  - mapping parameters to `.env`.
- **Compose config.** `docker compose config` for every supported combination: 3 providers × platform Docker / source / skipped × storefront on or off × Elasticsearch on or off × Redis on or off × HTTPS or HTTP, plus capped limits. It needs no Docker daemon (verified in a sandbox), so it runs anywhere.
- **Smoke.** A non-interactive install with capped limits and `stable`, in HTTPS mode. It checks platform health and an authenticated API call. A second job migrates a layout-1 folder created with `release/1.0`'s `VirtoLocal_create_local_files.ps1`.

| Tier | Ubuntu | Windows | macOS |
|------|:-:|:-:|:-:|
| Unit (Pester 5) | ✓ | ✓ | ✓ |
| Compose config | ✓ | ✓ | ✓ (Compose installed by the workflow) |
| Smoke | ✓ (native) | ✓ (Docker inside WSL2) | ✓ on `macos-15-intel` (colima); ✗ on arm64 |

- **Runners** (probe run, follow-up *Amendments*). The Windows runner's own Docker daemon runs only Windows containers, so the smoke job installs a WSL2 distribution with Docker in it. It takes about 2 minutes, and about 1–2% of WSL2 jobs hang (runner-images#14938), so the job has a timeout. macOS arm64 runners can't start a VM, so the macOS smoke job uses `macos-15-intel` with colima; setup takes about 7 minutes. The smoke job uses PostgreSQL and leaves out Kibana, to fit the runners' memory.

## 13. Left to the plan

- Release and PR order: cutting and tagging `release/1.0`, one PR against `dev` or two (F4), and switching the README one-liner within the `v2.0.0` release.

## 14. Trade-offs

- **Link files and overlays** are extra files, and a hand-edited `COMPOSE_FILE` depends on the next script run to add them. The price buys feature files that stay independent, each service defined once, and the Compose-native `.env`.
- **Platform settings are defined twice**: in the compose YAML for Docker and in the settings-file function for a source run (§5.3). The price buys a `docker compose` that always sees the current `.env`; the drift test in §12 guards it.
- **The settings file needs .NET 10** and the content root as the working directory (H5). Older platforms and IDEs launched from elsewhere don't see it.
- **HTTPS by default** brings in a dev-cert export and Elasticsearch security (setup container, Kibana sign-in). HTTP mode keeps today's behavior one switch away.
- **Migrated folders change in two deliberate ways**: ports bind to localhost (D9), and the platform starts using Redis as its cache backplane (D6).

## 15. To verify while implementing

Every design choice is decided except the lifetime of obsolete parameters, left open on purpose (B1); only C1's saving of a generated admin password is assumed rather than asked. These facts are still unverified:

- Compose v2.18.0 support for `${COMPOSE_PROJECT_NAME}` and nested defaults (D3; verified on v5.5.1).
- That the chain .NET builds for the Elasticsearch cert contains the setup CA, so the CA fingerprint matches (E11).
- The working directory that Rider, VS Code and Visual Studio use for a platform launch, which must be the content root for the settings file (H5).
- That the platform exits when the database or Elasticsearch isn't ready after a daemon restart, so its restart policy retries it (D10).
- The Windows Docker CLI and Compose reaching the Docker daemon inside WSL2 on the Windows runner (G1).

## Amendments

### 2026-11-10: switching between HTTP and HTTPS (plan review)

The original text above is unchanged. These corrections came up while checking the [implementation plan](../plans/2026-11-10-env-first-redesign.md) against the upgrade path, in which a migrated folder starts in HTTP mode and is switched to HTTPS later:

- **§5.1, "Ports keep their keys across modes":** this no longer holds for `FRONTEND_PORT`, whose standard port differs by scheme.
  - Switching to HTTPS rewrites `80` to `443`, and switching to HTTP rewrites `443` to `80`. Any other value is the user's and is never changed.
  - `PLATFORM_PORT` keeps its value in both modes.
  - A fresh install with `-allowInsecureHttp` therefore gets `80`. (Plan P17.)
- **§8.1, build step 3:** start also exports the dev certificate when the export is missing, before copying it into the certificates volume. A folder built in HTTP mode can then switch to HTTPS without a rebuild.
- **§15, new fact to verify:** whether Elasticsearch accepts `ELASTIC_PASSWORD` when security is first turned on over data created with security off, and keeps the data across repeated mode switches. Plan Task 14, step 7.
- **Not part of this redesign:** a rebuild on another release channel leaves the old modules in the `modules-data` volume. The fix (dropping that one volume, never the DB, Elasticsearch or CMS volumes) belongs to the separate update PR.

### 2026-11-11: corrections from implementation (execute phase)

The original text above is unchanged. These corrections came up while implementing the [plan](../plans/2026-11-10-env-first-redesign.md); each was verified with tests, and the live ones on a scratch stack. The R numbers are the executor's rulings.

- **§8.1, start step 8 (R31):** sample data runs first, then the admin password (C1), the reverse of the text above.
  - The sample data's `Users` section carries the `admin` account with the hash of `store`. The Backup & Restore import updates the existing admin with it, so a password applied before the import is undone.
  - Verified live: with the old order, after the first non-interactive start `ADMIN_PASSWORD` was refused and `store` accepted. With the new order `ADMIN_PASSWORD` is accepted and `store` refused.
  - C1 and P10 are unchanged: the sign-in candidates are still `ADMIN_PASSWORD`, then `store`. Plan Task 11 Step 3 lists the old order. (Commit 87b10cf.)
- **§8.1, remove (R34):** remove, both full and `-keepData`, first stops the source-run platform when its pid file exists, as stop does.
  - Otherwise remove deletes the pid file while the platform keeps running, and no script can find that process again. (Commit 89d3663.)
- **§8 *Optional files* and §9 (R35):** a `.env` without `START_LOCAL_LAYOUT` counts as written by a wrapper (layout 2: missing keys are added and the marker is written) only when it sets a non-empty `COMPOSE_FILE`.
  - A layout-1 file never has one. Any other `.env` without the marker goes to migration unchanged, as §9 says ("a missing key means layout 1").
  - The installer must not write `START_LOCAL_LAYOUT` to a layout-1 file before migration has run. Otherwise a folder from before `DB_PROVIDER` existed would be relabelled instead of migrated. It would lose `VOLUME_PREFIX=virto` and its data would be orphaned.
  - Contract for a cloud wrapper: write `COMPOSE_FILE`, or `START_LOCAL_LAYOUT=2`. A wrapper `.env` with neither fails with migration's "`DB_PROVIDER` is missing" message. (Commit 1ffc8f7.)
- **§12, CI (R40):** the unit and Compose jobs skip docs-only changes with a job-level `if:`.
  - GitHub evaluates that condition before it expands the matrix, so a skipped matrix job never reports its per-OS checks (`unit (ubuntu-24.04)` and so on). A branch rule that requires them would wait forever.
  - An aggregator job, `ci-result`, depends on every test job, always runs, and fails only when one of them failed or was cancelled. A skipped job counts as a pass.
  - `ci-result` is the one check to require in branch protection.
  - The docs-only gate errs toward running the tests: if it cannot read the changed files, the tests run. (Commit b3e0165.)
- **§12, Smoke (R42):** the smoke scripts pull images with `docker compose pull --ignore-pull-failures`, not `--ignore-buildable`.
  - The platform and storefront services name a locally built `image:` and have no `build:` section. So `--ignore-buildable` still tries to pull them from the registry, exits 1, and stops the other pulls.
  - A public image that really is missing therefore fails at `docker compose up`, not at the pull. (Commit 4eb0311.)
- **§5 tree, §6 and A8 (compose folder; a user decision, not an executor ruling):** only the base file, `docker-compose.yml`, stays in the solution folder. Every other compose file moves to `docker-compose/` and drops its prefix: `docker-compose.<suffix>.yml` becomes `docker-compose/<suffix>.yml` (for example `docker-compose/https.yml`, `docker-compose/platform-elasticsearch.yml`, and the generated `docker-compose/platform-modules.yml`). `COMPOSE_FILE` lists them with `/` on every OS.
  - Plain `docker compose` in the folder keeps working: it resolves the `COMPOSE_FILE` paths against the working directory. Because the base file comes first, the folder stays the project directory and still gives the default project name.
  - Relative paths inside a file in `docker-compose/` resolve against the solution folder, not against `docker-compose/` (verified on v5.7.0). The built-in files have none. A user's override with a `./` bind mount must be written relative to the solution folder.
  - `Get-ComposeFileList` reads a hand-written `\` as `/`, so `docker-compose\postgres.yml` in `.env` on Windows still matches the catalog.
  - The payload ships `docker-compose.yml` and the `docker-compose/` folder. When it installs into a layout-1 folder, it deletes exactly the three layout-1 provider files (`docker-compose.{postgres,mysql,sqlserver}.yml`) next to the base file, which it used to overwrite. Other root compose files, such as a user's override, are left alone.
  - §4.1: a saved old installer run without `-branch` now gets a 404 for those three provider files. The failed downloads are not fatal (no `$ErrorActionPreference = 'Stop'`; verified against a real 404 from `raw.githubusercontent.com`), so the installer still reaches the guards.
  - R35 contract: a cloud wrapper that writes `COMPOSE_FILE` must use the `docker-compose/<suffix>.yml` names. There is no compatibility shim for the flat names, because layout 2 is unreleased. A `.env` that lists them gets them treated as unknown files and fails with "lists no database provider".
  - Verified with the unit and Compose tiers (the Compose tier on v5.7.0 and on v2.18.0), and with `docker compose config` in a `Copy-Payload` folder with the default HTTPS list.
