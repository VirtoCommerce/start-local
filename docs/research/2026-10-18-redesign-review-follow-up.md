# Follow-up research for the start-local redesign review

Date: 2026-10-18. These facts back the changes made to the [redesign spec](../specs/2026-10-15-env-first-redesign.md) and its [decision log](../specs/2026-10-15-redesign-decisions.md) after the user's review of 2026-10-18. The [fact check](2026-10-15-redesign-fact-check.md) holds the earlier evidence.

*Live* means tested on this machine: Ubuntu 24.04, .NET SDK 10.0.400, Docker Compose v5.6.0. Throwaway files were removed after each test.

## Summary

| # | Question | Verdict | Impact on the design |
|---|----------|---------|----------------------|
| 1 | Can two source-run platforms on one machine have separate config? | Confirmed (live + source) | A per-folder `VirtoCommerce.Platform.Web.settings.json` replaces user secrets (H5) |
| 2 | HTTPS as overlay files instead of `.http` variants | Confirmed (live) | `.https.yml` overlays; no duplicated service definitions (E13) |
| 3 | Virto Commerce release channel names | Confirmed (docs + source) | `RELEASE_CHANNEL` = `stable`, `stable:<N>`, `edge`, `custom` (B8) |
| 4 | Restart policy in the reference repo | Confirmed (source) | `restart: unless-stopped` for autostart (D10) |
| 5 | Which GitHub-hosted runners can run the stack | Confirmed (docs); probe pending | Smoke on Ubuntu only; unit and Compose tiers on all three OSes (G1) |

## 1. Per-folder config for a platform run from source

**The user-secrets store can't be split per folder.**
- `UserSecretsId` is compiled into the assembly as `UserSecretsIdAttribute`. A prebuilt DLL can only be pointed at another store by changing `HOME` / `APPDATA` for the process (live).
- `dotnet build -p:UserSecretsId=X` works, but the next plain build, which is what an IDE runs, restores the shared ID (live).
- A `UserSecretsId` environment variable has no effect; the csproj value wins (live).
- A parent `Directory.Build.props` is never reached, because vc-platform's own root `Directory.Build.props` stops the search. An untracked `Directory.Build.targets` at or above the checkout root does override the ID, `dotnet user-secrets` included (live). It can't help a prebuilt folder.

**What the platform loads** (vc-platform `dev`, `src/VirtoCommerce.Platform.Web/`, source):
- `Program.cs` (about lines 31–55) runs an early module-loading step. It reads only `appsettings.json`, `appsettings.{env}.json` and environment variables, and it takes the environment name only from `ASPNETCORE_ENVIRONMENT`.
- The main host is `Host.CreateDefaultBuilder(args)`. `Startup.cs` adds no configuration sources.
- `appsettings.Development.json` and `Properties/launchSettings.json` are tracked in git, so writing either dirties the checkout, and `.git/info/exclude` can't hide a tracked file.
- A custom environment name loses Development-only behavior. Module loading skips the development probing paths, user secrets aren't loaded, and three `Startup.cs` branches change (lines 391, 458, 765).

**.NET 10 loads `{ApplicationName}.settings.json` and `{ApplicationName}.settings.{env}.json` from the content root** (dotnet/runtime#116987). A minimal `dotnet new web` app on SDK 10.0.400 listed these configuration providers, in order (live):

1. `appsettings.json`
2. `appsettings.Development.json`
3. `Probe.settings.json`
4. `Probe.settings.Development.json`
5. environment variables

A value set only in `Probe.settings.Development.json` was read. The file is watched for changes: rewriting `Probe.settings.json` while the app ran changed the value it read within about a second (live).

**vc-platform ships no such file.** GitHub code search for `filename:VirtoCommerce.Platform.Web.settings.json` in `VirtoCommerce/vc-platform` returned 0 results, and `src/VirtoCommerce.Platform.Web/` on `dev` holds only `appsettings.json`, `appsettings.Development.json`, `appsettings.Production.json` and an unrelated Azure Functions `local.settings.json`. The user's prebuilt platform folder has the same four JSON files. So start writing the file overwrites nothing of the platform's.

Constraints:
- **User secrets win** over this file, and so do environment variables (live, in the subagent's test). Keys left in the shared `~/.microsoft/usersecrets/VirtoCommerce.Platform.Web/secrets.json` shadow the per-folder values.
- **The content root is the working directory.** Under `dotnet X.dll` the file is read from the current directory, not the DLL's folder, and so are the platform's relative `modules` paths. `--contentRoot` also worked. Which directory Rider, VS Code and Visual Studio use by default was **not checked**.
- **vc-platform `dev` targets `net10.0`** (csproj line 3). An older platform on .NET 8 or 9 doesn't load the file.
- The early module-loading step doesn't read it, so the file must not carry module path settings.

## 2. HTTPS as overlay files (live)

The spec's first draft had each feature in two alternative files, `docker-compose.<feature>.yml` (HTTPS) and `docker-compose.<feature>.http.yml` (HTTP). Every setting the two share (image, ports, volumes, `depends_on`) would be written twice.

Test, with `COMPOSE_FILE=docker-compose.yml;docker-compose.elasticsearch.yml;docker-compose.elasticsearch.https.yml`:
- The base feature file defined `es` with `xpack.security.enabled=false` in list-form `environment:`.
- The overlay added an `es-setup` service, made `es` depend on it (`service_healthy`), mounted the certificates volume, and set `xpack.security.enabled=true` plus `xpack.security.http.ssl.enabled=true`.

`docker compose config` merged list-form `environment:` entries **by key**: the overlay's `xpack.security.enabled=true` replaced the base value, and the base-only `discovery.type` stayed. The overlay's new service and `depends_on` were accepted, because both are defined in the same overlay. No `!reset` or `!override` was needed.

## 3. Release channel names

- **Docs:** the Virto Commerce "Release strategy overview" names the channels **Stable**, **Edge** and **Preview**. Stable ships about once a quarter with full regression, end-to-end and load testing; hotfixes go to the two latest stables. Edge is published daily with automated tests only.
- **A stable release is a numbered cycle:** "Stable 15", "Stable 16" ("Upgrade to Stable 15"; `vc-modules/bundles/RELEASE_PROCEDURE.md`). The product-versions page labels the same cycles `v3-<year>-S<N>`, for example `v3-2026-S15`. There is no LTS label.
- **vc-modules `master`:** `bundles/` has `latest`, `v0`–`v12`, `v14`, `v15`, `v16` (no `v13`). `bundles/stable.json` maps keys `"0"`…`"16"` (no `"13"`) and `"latest"` to each bundle's `package.json`. `latest` is a moving alias, currently the same as v16 (platform 3.1076.6).
- **vc-build** (`src/VirtoCommerce.Build/PlatformTools/Build.PackageManager.cs`, source):
  - `-v <bundle>` (`BundleName`, default `"latest"`), `-Edge`, and `-BundlesUrl` (default `bundles/stable.json`).
  - Stable is simply the absence of `-Edge`.
  - The bundle lookup is an exact match on the `stable.json` key: `-v 16` works, `-v v16` doesn't, and an unknown key crashes the download without a clear message.
  - There is no `-Stable` parameter, though one docs example uses it.
- **Frontend:** each bundle pins the storefront through a `ThemeB2BVue` URL (v16 → 2.59.0). vc-build never reads it. Edge has no pin; "the latest vc-frontend release" is start-local's own rule.

## 4. Autostart in the reference repo

`asvishnyakov/virtocommerce` `docker-compose.yml` sets `restart: unless-stopped` on every long-running service (`mssql`, `elastic-search`, `kibana`, `redis`) and none on the one-shot `elastic-setup`. Its start script is `docker compose up -d`. start-local today sets `restart: unless-stopped` only on `vc-platform-web` and `on-failure` on `es`.

## 5. GitHub-hosted runners

Sources: `actions/runner-images` image READMEs (Ubuntu 24.04 20261012, Windows 2025 20261013, macOS 15 arm64 20260907, macOS 15 Intel 20260824), GitHub's hosted-runner reference, and runner-images issues #9460, #10563 and #14938. Docs only; no workflow was run.

| | ubuntu-24.04 | windows-2025 | macos-15 / macos-latest (arm64) |
|---|---|---|---|
| Docker daemon | Docker 28.0.4, Linux containers | Docker 29.7.2, **Windows containers only** | none |
| Linux containers | yes | only through Docker inside WSL2 (nested virtualization exists; about 1–2% of WSL2 jobs hang, #14938); untested | **impossible**: Apple's Virtualization Framework has no nested virtualization; colima fails with `HV_UNSUPPORTED` (#9460) |
| `docker compose` | 2.38.2 | 2.40.3 | not installed; `docker/setup-compose-action` or Homebrew |
| pwsh / Pester 5 | 7.6.x / 5.9.0 | 7.6.x / 5.9.0 (Pester 3.4.0 also present) | 7.6.x / 5.9.0 |
| .NET 10 SDK | 10.0.401 | 10.0.401 | 10.0.400 |

- `macos-latest` now maps to macOS 26 arm64. `macos-13` (Intel) was retired on 2025-12-04; `macos-15-intel` remains until Fall 2027 and has no Docker either. colima might work there, but runs are reported as very slow. Untested.
- Private-repo Ubuntu runners have 2 vCPU and 8 GB, which is tight for Elasticsearch, Kibana, the platform and SQL Server together.
- `docker compose config` needs no daemon (live: exit 0 with `DOCKER_HOST` pointing at a missing socket), but the runners' Compose 2.38 and 2.40 are older than the v5.6.0 tested here.

## Amendments

### 2026-10-18: runner probe (live)

[runner-probe run 39082797326](https://github.com/asvishnyakov/start-local/actions/runs/39082797326) on the user's fork, commit `7d896ca`. Every probe step ran with `continue-on-error`, so the results below come from the job logs, not from the step conclusions, which all read `success`.

| Runner (image) | Linux containers | Evidence |
|---|---|---|
| `ubuntu-24.04` | **Yes, native** | `docker run --rm --platform linux/amd64 alpine uname -a` printed `Linux … x86_64` |
| `windows-2025` (`windows-2025-vs2026` 20261007.264.1) | **Yes, through WSL2**; not on the native daemon | Native: `docker info` gave `windows/x86_64`, and the alpine run failed with `no matching manifest for linux/amd64`. WSL2 had no distribution installed. `wsl --install -d Ubuntu-24.04 --no-launch`, then `apt-get install docker.io docker-compose-v2` and `dockerd` inside it, gave `OSType` `linux` and ran `hello-world` (amd64). The step took about 1 min 45 s |
| `macos-15` (arm64) | **No** | Homebrew installed colima 0.10.3, Docker 29.8.0 and Compose 5.5.1, but `colima start` failed at VM creation with the `vz` driver: `error starting vm: error at 'creating and starting': exit status 1` |
| `macos-15-intel` | **Yes, through colima** | `colima start --cpu 3 --memory 6` came up; `docker info` gave `linux/x86_64` and `hello-world` ran. The job took 7 min, most of it Homebrew and the colima VM |

On every runner, PowerShell 7.6.6 and Pester 5.9.0 were present and `Import-Module Pester -MinimumVersion 5.0` loaded 5.9.0. .NET SDK 10.0.401 is on Ubuntu and Windows. `docker compose config` worked without a daemon on Ubuntu and Windows (Compose v2.40.3 on Windows). On macOS the Compose plugin comes from Homebrew (5.5.1), which installed on both architectures.

Untested: on Windows, the probe ran the Docker CLI inside WSL. The start-local scripts run in Windows `pwsh` with Windows paths, so they would need the Windows Docker CLI pointed at the WSL daemon (for example `DOCKER_HOST=tcp://localhost:2375`).
