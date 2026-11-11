# Fact check for the start-local redesign

Date: 2026-10-15. These facts back the [redesign spec](../specs/2026-10-15-env-first-redesign-design.md) and its [decision log](../specs/2026-10-15-redesign-decisions.md).

Each finding has a **verdict** and its evidence. *Live* means tested on this machine: Ubuntu 24.04, PowerShell 7.6.6, .NET SDK 10.0.400, Docker Desktop with Docker 29.8.2 and Compose v5.5.1. Throwaway containers, volumes and files were removed after each test.

## Summary

| # | Question | Verdict | Impact on the design |
|---|----------|---------|----------------------|
| 1 | Does `refs/heads/<branch-with-slash>` work in raw URLs? | Confirmed (live) | Old installers can use `-branch release/1.0` (A5) |
| 2 | Archive zips for branches and tags, and release-asset URLs | Confirmed (live + docs) | The payload is one zip (A2). Allowlists need `release-assets.githubusercontent.com` |
| 3 | `GET /releases/latest` semantics and rate limit | Confirmed (docs + live) | Usable for A7. It is 60 requests/h per IP without a token |
| 4 | `COMPOSE_FILE` / `COMPOSE_PATH_SEPARATOR` in `.env`, and `!reset` | Confirmed (live); minimum version partial | Scripts must `cd` into the folder. Minimum Compose is v2.18.0 (inferred) |
| 5 | Single-node mode on an existing `esdata` volume | Confirmed (live) | The capped-limits override is safe for existing folders |
| 6 | Re-running today's installer breaks DB volumes | Confirmed (live) | An existing bug, which B2 fixes |
| 7 | Elasticsearch heap auto-sizing | Confirmed (live) | No heap keys (D2) |
| 8 | Upgrading Elasticsearch 8 → 9 | Confirmed (docs) | Existing folders keep 8.18 (D7) |
| 9 | Search-provider module options and bundles | Confirmed (source) | **Revises D8.** Trust Elasticsearch through `CertificateFingerprint` |
| 10 | `SSL_CERT_FILE` / `SSL_CERT_DIR` semantics | Confirmed (docs + source) | A fallback only |
| 11 | `dotnet dev-certs` PEM export, Kestrel and Linux trust | Confirmed (live); partly from docs | E4 works |
| 12 | User secrets for a platform run from source | Confirmed (source) | H5 resolved |
| 13 | Module discovery and symlinks | Partial | H2 works on Linux; Windows junctions are unverified |
| 14 | Docker Desktop file sharing | Confirmed (live) | **New constraint:** certs go in a named volume; module mounts get a preflight check |
| 15 | `[Obsolete]` on script parameters | Confirmed (docs + live) | B1 shims use the attribute |
| 16 | Kibana's TLS in Elastic's official compose | Confirmed (live) | E3 follows the reference repo, not the official file |
| 17 | vc-frontend certificates | Confirmed (source + release ZIPs) | The Docker storefront needs a cert from start-local (E8) |
| 18 | Redis use by the platform | Confirmed (source) | D6 |
| 19 | Prior art: vc-platform `ModulesDevelop` and other products' installers | Reference | Supports A2, A6 and A7 |

## 1. Raw URLs with a slash in the branch name

`https://raw.githubusercontent.com/VirtoCommerce/vc-docker/refs/heads/feat/net10/linux/platform/Dockerfile` returns `HTTP/2 200`. The form without `refs/heads/` also returns 200. GitHub doesn't document this; the evidence is behavioural only.

## 2. Archive and release-asset URLs

- **Branch:** `github.com/VirtoCommerce/vc-docker/archive/refs/heads/feat/net10.zip` redirects (302) to `codeload.github.com/.../zip/refs/heads/feat/net10`, which returns 200 with `filename=vc-docker-feat-net10.zip`. The top-level folder is `vc-docker-feat-net10/`, so `/` becomes `-`. That naming is observed, not documented. GitHub's "Downloading source code archives" says only that the repository name is part of the directory structure.
- **Tag:** `vc-platform/archive/refs/tags/3.1083.0.zip` redirects to codeload, which returns 200 (`vc-platform-3.1083.0.zip`).
- **Latest release asset:** GitHub's "Linking to releases" documents `/releases/latest/download/<asset>`. Live, it redirects to `/releases/download/<tag>/<asset>`, then to **`release-assets.githubusercontent.com`**, then returns 200. Network allowlists such as the cloud-routine environment need that host. It is not `objects.githubusercontent.com`.

## 3. `GET /repos/{owner}/{repo}/releases/latest`

GitHub REST docs: "The latest release is the most recent non-prerelease, non-draft release, sorted by the created_at attribute". Rate limits: "The primary rate limit for unauthenticated requests is 60 requests per hour", per originating IP. A live call returned `x-ratelimit-limit: 60`. start-local has **no tags** as of this date.

## 4. Docker Compose

Live probe of `docker compose config` in a scratch project:

| Setup | Result |
|-------|--------|
| `.env`: `COMPOSE_FILE=docker-compose.yml:docker-compose.postgres.yml:docker-compose.capped.yml`, run inside the folder | All three files merged. `ulimits: !reset {}` removed the base file's `memlock` |
| Same `.env`, run from the parent folder with `--project-directory VirtoLocal` | `.env` **is** read from the project directory, but the relative paths in `COMPOSE_FILE` resolve against the **working directory**: `stat …/compose-probe/docker-compose.yml: no such file`. **The scripts must `cd` into the folder** (or use absolute paths) |
| Run from the parent folder with no flags | `no configuration file provided` |
| `COMPOSE_FILE` with `;` on Linux, no separator set | Fails; the default on Linux is `:` |
| `COMPOSE_PATH_SEPARATOR=;` in `.env`, then `COMPOSE_FILE` with `;` | Works. **One `.env` format can serve Windows and Linux** |
| `COMPOSE_FILE=docker-compose.yml:docker-compose.${DB}.yml`, with `DB` set in `.env` | Expanded |

From the docs:
- Defaults are `:` on macOS and Linux and `;` on Windows.
- The interpolation page says Compose reads `.env` from the project directory "both for self-configuration and interpolation". The envvars page's table says "working directory", which contradicts the live test; treat it as a docs error.
- `!override` carries a "Compose v2.24.4" badge in compose-spec `13-merge.md`.
- `!reset` has no documented version. It arrived with compose-go PR #380, merged 2023-04-25 and released in compose-go v1.13.5. docker/compose v2.18.0 is the first release pinning that version. So the **minimum is v2.18.0, inferred**.

## 5. Single-node mode on an existing data volume (live)

1. Start Elasticsearch 8.18.0 with start-local's current settings (`cluster.initial_master_nodes=es`, `bootstrap.memory_lock=true`, `--ulimit memlock=-1:-1`, `-m 1g`) on a named volume, and index one document.
2. Re-run on the same volume with `discovery.type=single-node`, `bootstrap.memory_lock=false` and no ulimits.

Result: the cluster was `yellow` with 1 node, the document was found (`found: true`), and the log had no errors.

## 6. Re-running today's installer breaks DB volumes (live)

`VirtoLocal_create_local_files.ps1` always rewrites `.env` with new `New-RandomPassword` values. The Postgres image applies `POSTGRES_PASSWORD` only when it initializes an empty data directory.

Test with `postgres:18.3`, matching start-local's environment:
1. Initialize with `firstPass1`.
2. Re-create the container with `secondPass2`, keeping the volume.

Logging in with `secondPass2` fails (`FATAL: password authentication failed for user "postgres"`), while `firstPass1` still works. After a re-run, the platform can't reach an existing Postgres database. MySQL and SQL Server images document the same first-init-only behavior; that was not tested here.

## 7. Elasticsearch heap auto-sizing (live)

Elasticsearch 9.5.5 with `-m 1g` reports `-Xms512m -Xmx512m` and `heap_max_in_bytes: 536870912`, the same as the reference repo's explicit `ES_JAVA_OPTS`.

## 8. Upgrading Elasticsearch 8 → 9

Elastic, "Upgrade your deployment": "To upgrade to the 9.0.x series, you must be on 8.18.x. To upgrade to 9.1.0 or later, you must be on 8.19.x". The 8.19 step is "required regardless of whether you perform a rolling upgrade or a full cluster restart". Also: "By default, 8.x Elasticsearch clients are compatible with 9.x" through REST API compatibility.

## 9. Search-provider modules and bundles

- **Repositories:** `VirtoCommerce/vc-module-elastic-search-8` targets Elasticsearch 8 and 9; `VirtoCommerce/vc-module-elastic-search-9` targets 9 and 10.
- **Options:** `ElasticSearch8Options` and `ElasticSearch9Options` share the same properties: `Server`, `User`, `Key`, **`CertificateFingerprint`**, `EnableDebugMode`, `RequestTimeout` and `LongRunningRequestTimeout`.
  - There is no `EnableCompatibilityMode` property, though start-local's compose sets `Search:ElasticSearch8:EnableCompatibilityMode=true` today. That setting is dead.
- **Binding:** the options bind to `Search:{ProviderName}`, with `ProviderName` set to `"ElasticSearch8"` or `"ElasticSearch9"`.
- **Activation** (vc-module-search `SearchProviderActive`): `Provider` matches the name case-insensitively, or any `DocumentScopes[].Provider` does.
- **Bundles:** `vc-modules/bundles/latest/package.json` (platform 3.1039.13) contains `VirtoCommerce.ElasticSearch8` and no ElasticSearch9.
- **Edge:** `vc-build install -Edge` keeps the modules in `modules_v3.json` whose `Groups` contain `"commerce"`. ElasticSearch8 has that group; ElasticSearch9 has no groups. **Neither bundle installs ElasticSearch9.**

## 10. `SSL_CERT_FILE` and `SSL_CERT_DIR`

The OpenSSL 3.0 `SSL_CTX_load_verify_locations` docs say each variable overrides its own default; neither adds to it. `openssl-env(7)`: `SSL_CERT_DIR` may list several directories separated by colons. .NET (`pal_x509_root.c`, `OpenSslCachedSystemStoreProvider`) loads both the file and every directory. So setting only `SSL_CERT_FILE` replaces the CA file while the default directory still loads. That conclusion comes from the code and was not tested.

## 11. `dotnet dev-certs`, Kestrel and trust

- **Export (docs, then live):** `dotnet dev-certs https --export-path x.pem --format PEM --no-password` writes `x.pem` plus `x.key` (plain text). Without `-np`/`-p`, only the public cert is exported.
- **Kestrel (live):** a minimal `dotnet new web` app run with `Kestrel__Certificates__Default__Path` / `…KeyPath` pointing at the export served HTTPS. `curl --cacert x.pem` returned 200. Microsoft documents the env-var form only with a PFX. aspnetcore's `ConfigurationReader.cs` reads `KeyPath` for every `Certificates` child, `Default` included.
- **Linux trust (docs):** .NET 9 added `dotnet dev-certs https --trust` for Ubuntu and Fedora. It covers Chromium browsers, Firefox and .NET `HttpClient`. It needs `openssl` and `certutil`, and the user must set `SSL_CERT_DIR=$HOME/.aspnet/dev-certs/trust:/usr/lib/ssl/certs`. SLES and RHEL are not supported.
- **This machine:** `--check --trust` reported the cert as untrusted, yet curl trusted it, because the cert was installed by hand as `/usr/local/share/ca-certificates/aspnet-dev-asvishnyakov.crt`. `--check --trust` doesn't detect trust added to the system store by hand. The printed trust instructions (E5) should offer both routes.

## 12. User secrets for a platform run from source

- `vc-platform` `dev`: `VirtoCommerce.Platform.Web.csproj` line 8 has `<UserSecretsId>VirtoCommerce.Platform.Web</UserSecretsId>`, and `Program.cs` uses `Host.CreateDefaultBuilder(args)`.
- `HostingHostBuilderExtensions` adds user secrets when `env.IsDevelopment()` and the entry assembly loads. It is a runtime check, so **`dotnet run` and `dotnet VirtoCommerce.Platform.Web.dll` behave the same** under `ASPNETCORE_ENVIRONMENT=Development` (from the code).
- The secrets file is `~/.microsoft/usersecrets/VirtoCommerce.Platform.Web/secrets.json`. Every platform checkout and build on the machine shares that one store. In the default builder, environment variables override user secrets.

## 13. Module discovery and symlinks

- `LocalStorageModuleCatalogOptions.DiscoveryPath` is a **single string** (`"modules"`), and `ProbingPath` defaults to `"app_data/modules"`.
- Discovery uses `Directory.EnumerateFiles(path, "module.manifest", SearchOption.AllDirectories)` and skips paths that contain `artifacts`.
- **Linux (live, .NET 10.0.12):** with a directory symlink `modules/modA`, the platform's discovery found both `modA/module.manifest` and `modA/bin/a.dll`.
- **Windows junctions:** not verified.

## 14. Docker Desktop file sharing (live)

Bind mounts from `/tmp`, `$HOME/.cache` and `/mnt/Programming/Management/...` all failed with `mounts denied: The path … is not shared from the host and is not known to Docker`. On this machine, `~/.docker/desktop/settings-store.json` shares only `/mnt/Programming/{AI chat/virto-oz-for-vccom,Marketplace,VirtoCommerce}`.

Today start-local uses named volumes only, so it never hit this. Two new features need host files inside containers:
- **Certificates:** they go into a named volume (`docker cp` through a helper container), which needs no file sharing.
- **Module source bind mounts:** these can't avoid it, so a preflight check runs `docker run --rm -v <path>:/x:ro …` and reports `mounts denied` with the fix.

## 15. `[Obsolete]` on script parameters

about_Functions_Advanced_Parameters (7.4–7.6) has a "System.Obsolete attribute" section. Live test (pwsh 7.6.6): passing `-OldName foo` printed `WARNING: Parameter 'OldName' is obsolete. Use -NewName instead`. There is no warning when the parameter isn't passed.

## 16. Kibana's TLS in Elastic's official compose (live)

`elastic/elasticsearch` `docs/reference/setup/install/docker/docker-compose.yml` on branches 8.0, 8.5, 8.11, 8.18 and 8.19: Kibana sets `SERVERNAME=kibana`, uses `ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES` for the link to Elasticsearch, and checks health with `curl -s -I http://localhost:5601`. None of these branches have `server.ssl`.

The reference repo (`asvishnyakov/virtocommerce`) has the official setup container almost word for word (same certutil, `kibana_system` password and wait loop), cut down to one node. Its Kibana also serves HTTPS (`server.ssl.enabled: true`) with a `kibana` cert from the same CA, and it adds `verification_mode: certificate` and localhost port binding. Kibana's own docs cover browser-to-Kibana TLS separately; that page was not checked here.

## 17. vc-frontend certificates

The `dev` branch (5,883 tree entries) has no committed certificates. `vite.config.ts` uses `vite-plugin-mkcert`, which writes `.certificates/{private,public}.pem` (gitignored) for `vite serve` only. Release ZIPs `vc-theme-b2b-vue-2.59.0.zip` and `vc-frontend-2.51.1.zip` contain no `.pem/.crt/.key/.pfx`. start-local's `frontend/Dockerfile` and `nginx.conf` listen on port 80 only.

## 18. Redis use by the platform

The platform uses Redis only when `ConnectionStrings:RedisConnectionString` is set (VC docs, Caching / "Setting up Redis": cache backplane). No start-local compose file, provider override or vc-docker `linux/platform/Dockerfile` (`feat/net10`) sets it. The platform only waits for `redis:6379` through `wait-for-it.sh`. Redis has been started, password-protected and persisted without being used since the first commit (`d34fc64`).

## 19. Prior art

### vc-platform `DockerCompose/ModulesDevelop`

Services:
- mssql 2022;
- `ghcr.io/virtocommerce/platform:${PLATFORM_VERSION:-dev-linux-latest}` on 8090 → 8080;
- Elasticsearch 8.19.4 with security off;
- Redis 7 with a password.

All four have health checks, and the platform waits on them through `depends_on`.

Modules:
- `${MODULES_VOLUME}` → `/opt/virtocommerce/platform/modules` and `${APP_DATA_MODULES}` → `app_data/modules`, both required (`:?`).
- You put a module folder under `MODULES_VOLUME` and restart the platform.

Platform environment:
- `ASPNETCORE_HTTP_PORTS=8080`, `VirtoCommerce__AllowInsecureHttp=true`, and `ConnectionStrings__RedisConnectionString`, so Redis is actually used here.
- `Search__Provider=${SEARCH_PROVIDER:-ElasticSearch8}`.

Configuration:
- A committed `.env` holds the defaults, and `.env.local` holds overrides: `--env-file .env --env-file .env.local`, or `COMPOSE_ENV_FILES=.env,.env.local`.
- `compose.override.yaml` covers anything beyond that.

### Other products' installers

Each script was read at HEAD.

| Product | Version resolution | Download |
|---------|--------------------|----------|
| Helm `get-helm-3` | `https://get.helm.sh/helm3-latest-version`, or `DESIRED_VERSION` / `--version` | One tarball plus `.sha256` |
| k3s `get.k3s.io` | `INSTALL_K3S_VERSION`, else a channel (default `stable`) resolved through `update.k3s.io/v1-release/channels/<channel>` | Binary plus `sha256sum-<arch>.txt` from GitHub releases |
| nvm `install.sh` | **Baked in** (`nvm_latest_version` returns `v0.40.8`), or `NVM_INSTALL_VERSION` | `git clone --depth=1` of the tag, falling back to raw downloads |
| Homebrew `install.sh` | Highest version tag, checked out as `stable` | `git init` plus `fetch --tags` |
| rustup `sh.rustup.rs` | `RUSTUP_VERSION`, else the latest | One `rustup-init` binary |
| bun `bun.sh/install` | A tag argument, else `releases/latest/download` | One zip |
| deno `deno.land/install.sh` | A version argument, else `dl.deno.land/release-latest.txt` | One zip |

All of them **resolve one version first, then download one artifact**. None downloads a list of files from a moving branch.

## Amendments

### 2026-10-15

- **§13, Windows:** the user reports, from their own earlier Windows setups, that the platform follows directory **symlinks** on Windows. Junctions remain untested and are no longer needed.
- **Symlinks over raw URLs (live):** `raw.githubusercontent.com` serves a symlink's link text, not its target. `kubernetes/kubernetes` `Makefile` (mode `120000`) returned HTTP 200 with the 19-byte body `build/root/Makefile`, for both the `<branch>/` and `refs/heads/<branch>/` URL forms. The contents API (`/repos/{owner}/{repo}/contents/Makefile`) resolves the link (`type: file`, 16,522 bytes). So a symlinked script can't be fetched by a raw-URL one-liner.
- **Compose interpolation (live, Compose v5.5.1):** `${COMPOSE_PROJECT_NAME}` interpolates in an image tag (`vc-platform:my_stack-latest` for folder `My_Stack`). `${VOLUME_PREFIX:-${COMPOSE_PROJECT_NAME}}` falls back when the key is empty. A variable inside an `environment:` list-form key interpolates (`Search__${SEARCH_PROVIDER}__CertificateFingerprint`).
- **CA fingerprint inside the ES image (live, ES 9.5.5):** the image is RHEL 9 with no `openssl`, but it has `sha256sum` and `base64`. For a CA made by `elasticsearch-certutil ca --pem`, `sed '/-----/d' ca.crt | base64 -d | sha256sum` gave `5978f1aa…00c1`, identical to `openssl x509 -fingerprint -sha256` on the host (colons removed, lowercased).
- **The user's ES trust today:** no fingerprint is configured. The ES CA is in the host store as `/usr/local/share/ca-certificates/elastic-ca.crt`, and no user secrets exist for `VirtoCommerce.Platform.Web` on this machine.
- **A 404 doesn't stop today's installer (live):** in `pwsh`, a failed `Invoke-WebRequest` prints an error and the next statement runs. `dev:VirtoLocal_create_local_files.ps1` doesn't set `$ErrorActionPreference = 'Stop'`.
