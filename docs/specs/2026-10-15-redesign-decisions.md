# start-local redesign: decision log

Status: **decided, spec drafted.** These are the decisions behind the [redesign spec](2026-10-15-env-first-redesign.md). Their evidence is in the [fact check](../research/2026-10-15-redesign-fact-check.md) and the [review follow-up](../research/2026-10-18-redesign-review-follow-up.md). This is a living document: update a decision in place when it changes.

## Goal

- Make one `.env` the source of truth, in place of parameters passed along create → build → start.
- Support unattended setup, for Claude Code cloud routines (part A of the VirtoOZ cloud-stack toolkit) and for CI.
- Serve HTTPS.

The style reference is [asvishnyakov/virtocommerce](https://github.com/asvishnyakov/virtocommerce): one `.env`, scripts without parameters that each do one job, and variation kept in data rather than in flags.

## Starting point

- The uncommitted draft on `feat/non-interactive` has 13 parameters on `VirtoLocal_create_local_files.ps1`, 11 on `build-VC-solution.ps1` and 7 on `start-VC-solution.ps1`. The same 5 start options are declared in all three scripts and forwarded down the chain. The redesign replaces this draft.
- start-local has no tags as of 2026-10-15.
- The direction is V2, "`.env` is the config": a template with empty secrets, filled at install. The installer asks only for empty keys and saves the answers; the other scripts read `.env` only. Added on top: a migration step, release pinning, and HTTPS.

## Decisions

### A. Releases and install

| # | Decision |
|---|----------|
| A1 | A release is a `release/X.Y` branch plus a `vX.Y.Z` tag. |
| A2 | The installer fetches the payload as one zip of the ref (`github.com/VirtoCommerce/start-local/archive/<ref>.zip`), not a list of single files. |
| A3 | Re-running the installer on an existing folder updates it in place. It keeps `.env` and runs migration. |
| A4 | Development stays on `dev`. `release/1.0` is cut from the current `dev` before the new layout lands. |
| A5 | `dev` keeps the four old scripts, `build-VC-solution.ps1`, `start-VC-solution.ps1`, `stop-VC-solution.ps1` and `remove-VC-solution.ps1`, as guards through 2.x. A saved copy of the old installer downloads all four from `dev`; it runs the build script only when the user agrees, and the user may run any of them by hand later. The new layout never calls them. When a folder already has an old-named script, the installer overwrites it with its guard; a folder without one never gets it. Each guard checks the folder's `.env` and runs nothing else. Without `START_LOCAL_LAYOUT`, an old installer wrote it, and the guard throws an error that explains (1) the old layout: download `VirtoLocal_create_local_files.ps1` from `release/1.0` and run it, or pass `-branch release/1.0` to the saved copy, (2) the new installer, which migrates the folder to the new version, and (3) that an old installer run over an existing folder has already regenerated the `.env` passwords (fact check §6). With `START_LOCAL_LAYOUT` present, it prints a warning that the script is renamed (`start-VC-solution.ps1` → `start.ps1`, and so on) and stops. The README and the release notes say the same. |
| A6 | The README one-liner downloads the latest release asset: `github.com/VirtoCommerce/start-local/releases/latest/download/install.ps1`. |
| A7 | With no ref given, the installer resolves the latest release through `GET /repos/VirtoCommerce/start-local/releases/latest`. |
| A8 | The scripts get short verb names: `install.ps1` (the installer and the release asset), `build.ps1`, `start.ps1`, `stop.ps1`, `remove.ps1`. The `docker-compose*.yml` files and the `scripts/` helpers keep their names. |
| A9 | `VirtoLocal_create_local_files.ps1` stays on `dev` as a forwarder for the old README one-liner (`raw.githubusercontent.com/VirtoCommerce/start-local/dev/VirtoLocal_create_local_files.ps1`). It holds nothing but downloading the latest release's `install.ps1` next to itself and calling `./install.ps1` with the same arguments, so old one-liners get the latest release, like the new one (A6). A symlink can't do this: raw URLs serve a symlink's link text ([fact check, *Amendments*](../research/2026-10-15-redesign-fact-check.md#amendments)). |
| A10 | The bootstrap installs layout-2 payloads only. A user who needs the old layout downloads `VirtoLocal_create_local_files.ps1` from `release/1.0` and runs it, as before. |

### B. `.env` behavior

| # | Decision |
|---|----------|
| B1 | Old parameters become obsolete shims: they print a warning and save their value into `.env`. Their lifetime is not decided yet. The parameters in B5 stay first-class instead. |
| B5 | First-class parameters, which take precedence over `.env` without a warning: `-targetFolder` / `-solutionFolder`, `-branch`, `-dbProvider` (rewrites `COMPOSE_FILE`, C3), `-releaseChannel` (B8), `-customPackagesJson`, `-customFrontendUrl`, `-skipSampleData` (keeps its `[bool]` type), `-nonInteractive` (B4), `-allowInsecureHttp` (E1), and the skip switches (B6). `-elasticsearchVersion` becomes an obsolete shim that writes `STACK_VERSION`, and `-vcSolutionVersion` one that writes `RELEASE_CHANNEL`. |
| B6 | Each optional part gets its own skip switch: `-skipPlatform`, `-skipFrontend`, `-skipElasticsearch`, `-skipKibana`, `-skipRedis`. They are separate parameters, grouped under one comment section in the `param` block, not merged into a single list parameter. Each persists, and `-<switch>:$false` undoes it. Docker parts persist by rewriting `COMPOSE_FILE`, the same way `-dbProvider` does. A platform run from source has no compose file, so `-skipPlatform` persists there as `SKIP_PLATFORM=true`. A skipped platform is the debugger case: start still prepares everything the platform needs (its settings file, module links, the services it depends on), then skips launching it and every step that needs it running (waiting, the installed-modules check, the admin password, sample data), and prints how to launch it. |
| B7 | The HTTP mode switch is `-allowInsecureHttp`, named after the platform's `VirtoCommerce:AllowInsecureHttp` (`PlatformOptions.cs`, which allows non-HTTPS requests to OpenIddict). PowerShell parameter names are camelCase and can't contain hyphens. |
| B8 | The solution to install is chosen by `-releaseChannel` / `RELEASE_CHANNEL`, named after Virto Commerce's "release channels". Its values follow the channel names and vc-build's switches ([follow-up §3](../research/2026-10-18-redesign-review-follow-up.md#3-release-channel-names)): `stable` (the default; vc-build's default bundle `latest`, the storefront from that bundle's `ThemeB2BVue`), `stable:<N>` (Stable N: `vc-build install -v <N>`, the storefront from bundle `v<N>`), `edge` (`-Edge`, the latest vc-frontend release) and `custom` (a package manifest). `<N>` is checked against the keys of `bundles/stable.json` before vc-build runs, because the numbers have gaps and an unknown key crashes vc-build. `latest-stable` is accepted as a synonym of `stable` with a warning. |
| B2 | The release ships `.env.example`, which is copied to `.env` only when the folder has none. |
| B3 | When a required key is empty, the installer asks once and saves the answer to `.env`. |
| B4 | A run is non-interactive when `-nonInteractive` is passed, or automatically when stdin is redirected or `CI=true`. |

### C. Settings in `.env`

| # | Decision |
|---|----------|
| C1 | Admin password: interactive runs never touch it, so the platform keeps `admin` / `store` with its change-password prompt. Non-interactive runs apply `ADMIN_PASSWORD` on every start through the API and clear the forced change on first sign-in; when the key is empty, they generate a random password and save it to `ADMIN_PASSWORD` (the saving is assumed). This includes migrated folders: running non-interactively over a folder used interactively is the user's choice. |
| C2 | The step switches (vc-build update, sample data, start after build) are per run only and not saved to `.env`. |
| C3 | `COMPOSE_FILE` in `.env` is the single source of truth for the compose file set. There is no separate `DB_PROVIDER` key; scripts infer the provider from the file list. A script parameter (`-dbProvider`, which stays first-class) rewrites `COMPOSE_FILE`. Switching by hand means editing the file list. |
| C4 | There are no generated settings files for Docker services. Compose files read `.env` through interpolation, using the list form of `environment:` so that keys can interpolate too (`Search__${SEARCH_PROVIDER}__…`, verified). The one value known only at runtime, the Elasticsearch CA fingerprint, never passes through `.env`: it travels through the certificates volume (E11). A platform run from source gets one generated settings file (H5). |
| C5 | Cross-feature wiring lives in **link files** that the scripts add to `COMPOSE_FILE` when both features are listed and remove otherwise (for example `docker-compose.platform-elasticsearch.yml` carries the platform's `depends_on: es`). Compose rejects a `depends_on` on an undefined service even with `required: false` (verified), so feature files can't hold it. A hand edit of `COMPOSE_FILE` may need one script run; Compose's error names the missing service. |
| C6 | Values nobody changes stay out of `.env` and are fixed in the compose files: the Elasticsearch cluster name (`elasticsearch`) and license (`basic`). Migration removes `ES_CLUSTER_NAME` and `ES_LICENSE` from old `.env` files. |

### H. Running each component from Docker or from source

Platform, modules and frontend can each run from Docker or from source, and the user chooses per component. A component that runs from source needs no Docker for itself.

| # | Decision |
|---|----------|
| H1 | One path key per component chooses the mode: `PLATFORM_SOURCE_PATH`, `MODULE_SOURCE_PATHS`. Empty means Docker; a path means source. The storefront is the exception (H8). |
| H2 | `MODULE_SOURCE_PATHS` is **either** a `;`-separated list of module `*.Web` folders (they have `module.manifest`) **or** exactly one `modules` folder, never both; a preflight check rejects a mix. A `*.Web` entry is placed at `modules/<module id>`: symlinked for a platform from source, bind-mounted for the Docker platform, either way replacing the installed copy of that module. A `modules` folder *becomes* the platform's modules folder, as in the user's own setup (`VirtoCommerce.Platform/modules -> ../modules`): for a platform from source, `<platform>/modules` is a symlink to it; for the Docker platform, it is bind-mounted at the container's modules folder. vc-build installs the package manifest's modules into it, so installed binaries and module source checkouts sit side by side; discovery is recursive (fact check §13). When `<platform>/modules` is a real directory with content, start refuses and names it rather than replacing it. |
| H3 | `start.ps1` launches a platform run from source in the background with log files, and `stop` stops it. |
| H4 | "Platform from source" means either a vc-platform checkout (`dotnet run`) or a prebuilt platform folder (`dotnet VirtoCommerce.Platform.Web.dll`). start detects which from the path's contents. |
| H5 | A platform run from source gets its config from a per-folder file, `VirtoCommerce.Platform.Web.settings.json`, which start writes into the platform's content root: `src/VirtoCommerce.Platform.Web/` of a checkout, or the prebuilt folder. .NET 10 loads that file after `appsettings.{env}.json` and watches it for changes ([follow-up §1](../research/2026-10-18-redesign-review-follow-up.md#1-per-folder-config-for-a-platform-run-from-source)). Each platform folder has its own file, so several source-run platforms can run side by side, for example VirtoOZ's management platform and a tenant platform. IDE runs read the same file. In a checkout, start adds the file name to `.git/info/exclude`. User secrets are not used: they are one store per machine (`UserSecretsId=VirtoCommerce.Platform.Web`) and they override this file, so the preflight warns when the shared store defines a key start writes. start launches with `ASPNETCORE_ENVIRONMENT=Development` and the content root as the working directory. |
| H6 | The user or the IDE builds the source components; start only runs what is already built, and fails fast when it isn't. With `-skipPlatform` (B6), start doesn't need the build output, so a platform the user builds and runs from the debugger works. |
| H8 | start-local runs the storefront in Docker only: the vc-frontend nginx image, from its own compose file. A storefront run from source is the developer's own business: they configure it and run it with yarn, while start-local leaves the storefront compose file out and does nothing else. vc-shell custom apps stay with their module repos. |
| H9 | Optional services each get their own compose file (Elasticsearch, Kibana, Redis, storefront), listed in `COMPOSE_FILE` or left out. There are no profiles and no on/off keys, so `COMPOSE_FILE` remains the one mechanism. |
| H10 | Single-node Elasticsearch (no memory lock, no raised ulimits) is opt-in through an override file added to `COMPOSE_FILE`. The local default stays as it is today. |
| H7 | Every Docker/source combination must work. That includes a Docker storefront with a source platform, where nginx proxies to the host (`host.docker.internal`; Linux needs `extra_hosts: host-gateway`). |

### D. Compose and runtime

| # | Decision |
|---|----------|
| D1 | The Elasticsearch override is named for its purpose: `docker-compose.es-limited.yml`. It is for hosts that cap kernel resource limits, such as cloud VMs and CI: memlock 8 MiB, nofile 20,000, no `CAP_SYS_RESOURCE` (VirtoOZ research, *Probe 12*). It sets `discovery.type=single-node`, which puts Elasticsearch in development mode where failed bootstrap checks only warn, plus `bootstrap.memory_lock=false` and no `ulimits`. It is opt-in (H10). |
| D2 | There are no heap keys. Elasticsearch sizes its heap from the container's memory limit: verified 2026-10-15 with ES 9.5.5 and `-m 1g`, which gave `-Xms512m -Xmx512m`, the same as the reference repo's explicit value. `ES_MEM_LIMIT` stays the one memory knob. |
| D3 | Several stacks can run side by side. Volume names derive from the project (folder) name, `${VOLUME_PREFIX:-${COMPOSE_PROJECT_NAME}}_*`; migrated folders keep the `virto` prefix through `VOLUME_PREFIX`. Image tags derive from it too: `vc-platform:${COMPOSE_PROJECT_NAME}-latest` and `vc-frontend:${COMPOSE_PROJECT_NAME}-latest`. Both forms are verified on Compose v5.5.1; v2.18.0 is to be verified. Migration retags existing `local-latest` images, so migrated folders need no rebuild. |
| D4 | Docker Compose v2.18.0 or later is required: the first release with `!reset`, a minimum inferred from source ([fact check §4](../research/2026-10-15-redesign-fact-check.md#4-docker-compose)). A preflight step checks it and prints a clear message. v1 support is removed from `docker-compose-helper.ps1`. |
| D5 | `depends_on: condition: service_healthy` chains with health checks replace the `wait-for-it.sh` entrypoints. |
| D6 | Redis is on by default and actually used: `docker-compose.redis.yml` is listed in `COMPOSE_FILE`, and the `platform-redis` link file sets `ConnectionStrings:RedisConnectionString` (cache backplane), as in the user's own repo and vc-platform's `ModulesDevelop`. Redis runs as a pure cache with no persistence. `-skipRedis` leaves it out. The `redisdata` volume of migrated folders is no longer used; migration leaves it alone and a full remove deletes it with the others. |
| D7 | New folders default to Elasticsearch 9. Existing folders keep the `STACK_VERSION` in their `.env` (8.18.0), so no migration is needed. If a user raises it by hand, 8.18 goes to 9.0 directly, but 9.1+ needs 8.19 first (Elastic upgrade docs). |
| D8 | The search provider is its own `.env` key, `SEARCH_PROVIDER=ElasticSearch8\|ElasticSearch9`, independent of `STACK_VERSION`. The default is `ElasticSearch8`, which supports Elasticsearch 8 and 9 servers; neither the `latest` nor the edge bundle ships ElasticSearch9 ([fact check §9](../research/2026-10-15-redesign-fact-check.md#9-search-provider-modules-and-bundles)). A user who installs ElasticSearch9 changes the key. |
| D9 | Published ports bind to `127.0.0.1` by default, for everyone, migrated folders included. `BIND_ADDRESS=0.0.0.0` re-enables remote access, and the release notes say so. |
| D10 | Docker services start again with the Docker daemon, as in the reference repo ([follow-up §4](../research/2026-10-18-redesign-review-follow-up.md#4-autostart-in-the-reference-repo)): every long-running service has `restart: unless-stopped`; one-shot containers such as the Elasticsearch setup have none. `stop` removes the containers, so a stopped stack stays stopped. A platform run from source is not restarted. Docker Desktop must itself be set to start at sign-in. |

### E. HTTPS

| # | Decision |
|---|----------|
| E1 | The stack serves HTTPS only by default, with no HTTP. A switch (a flag that rewrites `COMPOSE_FILE`) makes it HTTP-only instead; it is never both at once. Migration puts existing folders in HTTP mode so their URLs keep working. |
| E2 | Platform, storefront, Kibana and Elasticsearch all get HTTPS. |
| E3 | Elasticsearch and Kibana follow the reference repo, which is Elastic's official Docker Compose setup (`elastic/elasticsearch` `docs/reference/setup/install/docker/`, compared 2026-10-15) cut down to one node. A setup container runs `certutil ca` + `cert` from `instances.yml`, sets the `kibana_system` password, and gates the others through `service_healthy`. TLS is on for HTTP and transport. The official compose files (checked for 8.0, 8.5, 8.11, 8.18, 8.19) serve Kibana over plain HTTP, with TLS only on the link to Elasticsearch. The reference repo's Kibana serves HTTPS itself (`server.ssl.enabled`), and start-local follows it. |
| E4 | The platform uses a `dotnet dev-certs https` certificate. A platform run from source uses it natively. For the Docker platform, the cert is exported as PEM (`--format PEM --no-password` gives `.pem` + `.key`) and served by Kestrel through `Kestrel__Certificates__Default__{Path,KeyPath}`, verified live. |
| E10 | The `dotnet dev-certs` export (the one certificate made on the host) reaches the Docker platform and storefront through a **named volume** (copied in with `docker cp`), not a bind mount. Docker Desktop refuses bind mounts from paths that aren't in its File Sharing list ([fact check §14](../research/2026-10-15-redesign-fact-check.md#14-docker-desktop-file-sharing-live)), so plain Docker use needs no File Sharing setup. File Sharing is a prerequisite only for running modules from source: `MODULE_SOURCE_PATHS` bind mounts can't avoid it, and the preflight checks it. |
| E11 | The platform trusts the Elasticsearch CA through the module's `CertificateFingerprint` option, and Compose carries it end to end, like the CA itself. The setup container writes `ca/ca.fingerprint` to the certificates volume next to `ca.crt`. The ES image has no `openssl`, so it uses `sed '/-----/d' ca.crt \| base64 -d \| sha256sum`, which matches `openssl x509 -fingerprint -sha256` (verified with ES 9.5.5). The Docker platform's entrypoint (D5) reads that file into `Search__${SEARCH_PROVIDER}__CertificateFingerprint` before starting `dotnet`. For a platform run from source, start copies it from the volume into the platform's settings file (H5). The user's own setup trusts the CA in the host store instead (`/usr/local/share/ca-certificates/elastic-ca.crt`), which a Docker platform can't see, and E5 rules out installing it. This replaces the `SSL_CERT_FILE` idea. |
| E12 | HTTP mode (`-allowInsecureHttp`) restores today's behavior for all four endpoints, Elasticsearch security off included, so migrated folders keep their URLs and sign-ins. |
| E13 | HTTPS is a layer of overlay files, not a second copy of each file. A feature or link file holds the settings both modes share, with HTTP behavior; its `docker-compose.<name>.https.yml` overlay adds TLS (the Elasticsearch setup container, certificates, HTTPS URLs) and overrides `environment:` entries by key, verified live ([follow-up §2](../research/2026-10-18-redesign-review-follow-up.md#2-https-as-overlay-files-live)). The base file's overlay, `docker-compose.https.yml`, holds the certificates volume and is the mode itself: the stack is in HTTPS mode exactly when `COMPOSE_FILE` lists it. The installer lists it unless `-allowInsecureHttp` is passed, and normalization derives every other overlay from it, so skipping and re-adding features never changes the mode. `-allowInsecureHttp` removes it and the rest. |
| E5 | The scripts never install certificate trust on the host. They print instructions instead. |
| E6 | TLS terminates in each service (Kestrel, nginx, Kibana, Elasticsearch). There is no shared reverse proxy. |
| E7 | vc-frontend ships no certificate: `vite-plugin-mkcert` covers only its dev server (`.certificates/`, gitignored), and the release ZIPs contain none (checked 2.59.0 and 2.51.1). So the Docker storefront's nginx needs a certificate from start-local (E8). |
| E8 | The Docker storefront's nginx reuses the `dotnet dev-certs` PEM export that the Docker platform mounts: one localhost cert for both. |
| E9 | Kibana's certificate comes from the Elasticsearch setup CA: `instances.yml` gets a `kibana` entry, and the setup health check waits for both certs. |

### F. Migration and delivery

| # | Decision |
|---|----------|
| F1 | Every script first runs an idempotent migrate step, which does nothing when the folder is current. |
| F2 | Destructive migration steps ask for confirmation in interactive runs. Non-interactive runs go ahead and log what they did. Layout 1 → 2 has no such step: D3, D6 and D7 need no data changes. |
| F3 | The uncommitted draft has been stashed by the user. Work continues on `feat/non-interactive`, which is now at the same commit as `dev`. `docker-compose.es-single-node.yml` and `scripts/reset-admin-password.ps1` in the stash serve as reference. |
| F4 | Delivery: cut `release/1.0`, then one PR, or two if it grows too large. Decide once the size is known. |
| F5 | The decision log and the spec live in start-local's `docs/`. The `/docs/*` rule is removed from `.gitignore`. |
| F6 | `remove` has two levels. A full remove deletes the containers, the volumes, the images and the folder, as today. `-keepData` deletes the containers, the network, the images and the payload files, and keeps the volumes and `.env`: the volumes are useless without the passwords in `.env` (fact check §6). Re-running the installer over the folder brings the stack back with its data. |

### G. Testing

| # | Decision |
|---|----------|
| G1 | CI runs on GitHub-hosted runners in three tiers ([follow-up §5 and *Amendments*](../research/2026-10-18-redesign-review-follow-up.md#amendments)). Pester unit tests and `docker compose config` run on Ubuntu, Windows and macOS. The full-stack smoke test runs where hosted runners can run Linux containers, as the probe showed: Ubuntu natively, Windows through Docker inside a WSL2 distribution, and macOS on the `macos-15-intel` runner through colima. macOS arm64 runners can't run Linux containers. The macOS smoke lane ends when GitHub retires its last Intel image (planned for Fall 2027). |

## Compatibility surface

`release/1.0` covers saved copies of the old installer (A5). The new layout on `dev` must still keep these working:

1. Existing `VirtoLocal/.env` files. Scripts fill missing keys with today's defaults and keep existing values and passwords.
2. Docker state. Volume names `virto_*` and the data in them stay usable: DB passwords must still match initialized volumes, and Elasticsearch config changes must work on the existing `esdata01`. Service names and the project name derived from the folder also stay. Built images stay usable: migration retags `local-latest` to the per-project tag (D3).
3. Ports, URLs, and the `admin` / `store` sign-in in interactive runs (C1).
4. Prerequisites: PowerShell 7, and the Docker Compose version (see D4).

## Open questions

These are asked in order; earlier answers may change later questions.

- **B1:** the shim lifetime, left undecided on purpose.
- **E11:** the fingerprint format the module accepts (lowercase hex without colons, as written, or the colon form) is to be confirmed when implementing.
- **vc-build installing into an external `modules` folder** (H2) for the Docker platform: the vc-build option that targets it is not verified.
- **Compose v2.18.0** support for `${COMPOSE_PROJECT_NAME}` interpolation and nested defaults (D3) is not verified.
- **H5:** the working directory Rider, VS Code and Visual Studio use for a platform launch is not checked; the settings file is found only when it is the content root.
- **D10:** after a daemon restart, Docker starts containers without `depends_on` ordering. The platform must exit when the database or Elasticsearch isn't ready yet, so that its restart policy retries it; not verified.
- **G1:** on the Windows runner, the Windows Docker CLI and Compose have to reach the Docker daemon inside WSL2; that connection is not tested yet.
