# start-local env-first redesign: implementation plan

> **For agentic workers:** run through `/sdd-execute`, which is subagent-driven by default (`superpowers:subagent-driven-development`), task by task. Steps use checkboxes (`- [ ]`).

**Goal:** Rebuild start-local around one `.env`:
- a release-pinned installer;
- `COMPOSE_FILE` as the stack definition;
- Docker-or-source platform and modules;
- HTTPS by default;
- migration of existing `VirtoLocal` folders.

**Architecture:**
- Small PowerShell 7 entry scripts (`install`, `build`, `start`, `stop`, `remove`) dot-source one set of helper libraries under `scripts/`. Those libraries hold pure functions (covered by Pester) and thin side-effecting wrappers.
- Compose files are split into feature, link and `.https` overlay files. A catalog-driven normalizer keeps `COMPOSE_FILE` canonical.
- One settings function derives the source-run platform's config from the same `.env` as the compose YAML, and a drift test keeps the two equal.

**Tech stack:** PowerShell 7, Pester 5, Docker Compose ≥ v2.18.0, nginx templates (official image envsubst), Elasticsearch/Kibana setup-CA TLS, `dotnet dev-certs`, GitHub Actions.

**Spec:** [docs/specs/2026-10-15-env-first-redesign-design.md](../specs/2026-10-15-env-first-redesign-design.md). The executor reads it alongside this plan.

Short names used in `Reads:` lines:

| Name | Document |
|------|----------|
| SPEC | `docs/specs/2026-10-15-env-first-redesign-design.md` |
| DEC | `docs/specs/2026-10-15-redesign-decisions.md` |
| FC | `docs/research/2026-10-15-redesign-fact-check.md` |
| FU | `docs/research/2026-10-18-redesign-review-follow-up.md` |
| CIR | `docs/research/2026-10-18-ci-docker-caching.md` |

This repo has no `.claude/rules/`.

## Global Constraints

**Runtime and tooling**
- PowerShell 7, cross-platform (Windows, macOS, Linux). No bash launchers. `backend/entrypoint.sh` is the only shell script, and it runs inside the image.
- Docker Compose v2.18.0 or later. Compose v1 support is removed (D4).
- Pester 5 (`Import-Module Pester -MinimumVersion 5.0`). Use hashtables and `[pscustomobject]`, never PowerShell `class`.

**Scripts and configuration**
- `.env` is the only configuration. The only parameters forwarded between scripts are `-skipSampleData` and `-nonInteractive` (SPEC §2, §8).
- Every entry script (`install`, `build`, `start`, `stop`, `remove`) starts with `#Requires -Version 7.0` (SPEC §11) and runs `Invoke-StartLocalMigration` before anything else (SPEC §9, F1).
- Every script `Push-Location`s into the solution folder before it calls `docker compose`, and pops in `finally` (FC §4).
- Entry scripts and tests load the helpers only through `. "$PSScriptRoot/scripts/_init.ps1"`. Library files define functions only and do nothing at load time.
- The helper scripts that exist today keep their names (A8).

**Compose files**
- `environment:` uses the list form, and `depends_on` uses the mapping form with `condition: service_healthy`.
- Published ports: `"${BIND_ADDRESS:-127.0.0.1}:${<KEY>_PORT}:<container port>"` (D9).
- Volume names: `${VOLUME_PREFIX:-${COMPOSE_PROJECT_NAME}}_<suffix>`. The suffixes stay as they are today: `postgres_data`, `mysql_data`, `mssql_data`, `cms-content-data`, `modules-data`, `esdata01`, `redisdata` (legacy), plus the new `certs`.
- Images: `vc-platform:${COMPOSE_PROJECT_NAME}-latest`, `vc-frontend:${COMPOSE_PROJECT_NAME}-latest` (D3).
- Secrets interpolate with no default: `${DB_PASSWORD:?DB_PASSWORD is empty in .env}`, and the same for the other three.
- Long-running services have `restart: unless-stopped`; `es-setup` has no restart policy (D10).

**Behavior**
- Secrets are filled only when empty and never rotated. Generated values are alphanumeric, 16 characters.
- The scripts never install certificate trust (E5). Every platform API call uses `-SkipCertificateCheck`.

**Coding style** (user rules)
- Typed exceptions for unexpected errors. `$null`, `bool` or empty collections for expected failures.
- Full variable names in scriptblocks (`$entry`, not `$e`).

## Review Focus

Each item below gets a pinning test in the task named in parentheses.

1. **A `.env` hand-edited on Windows** (CRLF, UTF-8 BOM, a trailing blank line). It must read and round-trip unchanged (Task 1).
2. **Values the `.env` writer can't round-trip.** A user-typed `ADMIN_PASSWORD`/`DB_PASSWORD` containing `$`, `#`, quotes or a newline must fail with a message naming the key, never be written corrupted (Task 1).
3. **Re-running `start.ps1` on a stack that is already up**, for example after D10 autostart. The port check must not flag the stack's own published ports (Task 11).
4. **Re-running `install.ps1` over a used folder** (A3). Secrets stay byte-equal, and the user's own files in `COMPOSE_FILE` stay listed after the built-in files (Task 17).
5. **A stale `logs/platform.pid`** (crash, reboot, PID reused). `stop.ps1` must not kill an unrelated process; it removes the file (Task 16).

## Executor notes

- **Tests.** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit|Compose|All`. A single file: `pwsh -NoProfile -c "Invoke-Pester -Path <file> -Output Detailed"`.
  - The `Compose` tier needs only the `docker` CLI, not a daemon.
- **Live checks** run in a scratch solution made by `New-ScratchSolution` (Task 7) under `$TMPDIR`. Never run `remove.ps1` in the repo root.
- **Tests never bind-mount repo paths.** Docker Desktop File Sharing may refuse them (FC §14). Pipe content through stdin or `docker cp` instead.
- **"Stop and report".** A step marked this way checks an unverified fact (SPEC §15). On failure, stop the task loop and report. It goes back to `/sdd-design`; don't redesign.
- **The reference implementation** of the admin-password reset is the F3 stash `scripts/reset-admin-password.ps1`, if the stash is still present (DEC F3).

## Decisions (`P#`)

- **P1.** Provider-specific platform DB settings (`DatabaseProvider`, `ConnectionStrings__VirtoCommerce`, `depends_on vc-db`) move into link files `docker-compose.platform-{postgres,mysql,sqlserver}.yml` (C5). The source platform gets the same strings from `Get-DbSettings -Topology Host`.
- **P2.** Three more link files: `docker-compose.platform-frontend.yml`, `docker-compose.kibana-elasticsearch.yml` and its overlay `docker-compose.kibana-elasticsearch.https.yml`.
  - The overlay exists because a link listed after `kibana.https.yml` would override the HTTPS `ELASTICSEARCH_HOSTS` (merge order).
  - Kibana without Elasticsearch: normalization drops Kibana and warns.
- **P3.** Fixed container ports: 8080 for the platform and for the storefront (SPEC §6, *fixed container ports*).
- **P4.** start-local owns `backend/Dockerfile` and `backend/entrypoint.sh` (D5, E11). The Dockerfile is the vc-docker `feat/net10` Dockerfile, plus `curl`, plus `ENTRYPOINT ["/entrypoint.sh"]` and `CMD ["dotnet","VirtoCommerce.Platform.Web.dll"]`, and without `EXPOSE 80` and `ASPNETCORE_HTTP_PORTS`. `wait-for-it.sh` goes away.
- **P5.** nginx uses `NGINX_ENVSUBST_TEMPLATE_DIR`: `/etc/nginx/templates-http` (feature file) or `/etc/nginx/templates-https` (overlay), with `NGINX_ENVSUBST_FILTER=^PLATFORM_`.
  - `proxy_pass ${PLATFORM_SCHEME}://${PLATFORM_UPSTREAM};`
  - `PLATFORM_UPSTREAM` comes from the link file: `vc-platform-web:8080` or `host.docker.internal:${PLATFORM_PORT}`.
- **P6.** `-solutionFolder` defaults to `$PSScriptRoot`. `install.ps1`'s `-targetFolder` defaults to `VirtoLocal`.
- **P7.** `install.ps1` has two roles, selected by the hidden `-payloadPath` (SPEC §4.2): empty means bootstrap, set means payload install. The installer logic lives in `scripts/payload.ps1`, so tests can call it.
- **P8.** A storefront listed with no platform compose file means a host platform. Normalization adds `docker-compose.frontend-hostplatform.yml` (H7, B6).
- **P9.** The source platform listens on `Kestrel:Endpoints:Main:Url = <scheme>://${BIND_ADDRESS}:${PLATFORM_PORT}`, written to its settings file.
- **P10.** The admin sign-in candidates are `ADMIN_PASSWORD` (when set), then `store`. Non-interactive starts then apply `ADMIN_PASSWORD` (C1).
- **P11.** `docker-compose.es-limited.yml` also sets `cluster.initial_master_nodes=` (empty). Elasticsearch rejects that key together with `discovery.type=single-node` (verified in Task 7).
- **P12.** Required `.env` keys:
  - `COMPOSE_FILE` and `RELEASE_CHANNEL`;
  - `CUSTOM_PACKAGES_JSON` when the channel is `custom`.
  Interactive runs ask for them; non-interactive runs fail and name the key (B3, B4).
- **P13.** `remove.ps1` refuses a folder that contains `.git`. This guards the repo root, which is itself a valid solution folder.
- **P14.** The `modules-data` volume is unchanged here. Dropping it on rebuild belongs to the separate update PR, which keeps the DB, Elasticsearch and CMS volumes.
- **P17.** `FRONTEND_PORT` follows the mode's default (amends SPEC §5.1; see its *Amendments*).
  - Switching to HTTPS rewrites `80` to `443`; switching to HTTP rewrites `443` to `80`.
  - Any other value is the user's and is never touched.
  - `.env.example` keeps `443`. The installer applies the rule when `-allowInsecureHttp` is passed.
- **P15.** Delivery is one PR from `feat/non-interactive` to `dev`. The phases are its commit series, and the Phase D/E boundary is the fallback split (F6).
- **P16.** `docker-compose.platform-modules.yml` is generated, because the number of mounts varies. It is gitignored, written or removed on every `start.ps1` run, and lives in the catalog by name only.

## User steps (`F#`)

- **F1.** Before the PR merges:
  - cut `release/1.0` from `dev`;
  - tag `v1.0.0`;
  - publish GitHub Release `v1.0.0` with `VirtoLocal_create_local_files.ps1` as its asset (SPEC §4.1, A4).

  Task 20's migration lane needs this.
- **F2.** Right after the merge:
  - cut `release/2.0`;
  - tag `v2.0.0`;
  - run `gh release create v2.0.0 install.ps1 --target release/2.0`.

  Until then the forwarder fetches `releases/latest`, which is v1.0.0 and has no `install.ps1`.
- **F3.** After Task 16: launch the platform from Rider, VS Code and Visual Studio with a sentinel `"Logging":{"LogLevel":{"Default":"Trace"}}` in the settings file. Confirm that `trce:` lines appear (SPEC §15, H5).
- **F4.** After Tasks 19–20: push the branch to your fork and run `ci.yml` and `smoke.yml`. The executor doesn't push.
- **F5.** After Task 16, on Windows with Developer Mode: run `start.ps1` with `MODULE_SOURCE_PATHS` set to two `*.Web` folders. Confirm that the platform lists both modules (FC §13 *Amendments*).
- **F6.** If the PR is too large to review, split it at the Phase D/E boundary (F4). Don't advertise `dev` between the two merges.

## Where SPEC §15 gets verified

| SPEC §15 fact | Verified in |
|---------------|-------------|
| 1. Compose v2.18.0 | Task 7 step 6, Task 19 `compose-min` |
| 2. E11 certificate chain | Task 14 step 6 |
| 3. IDE working directory (H5) | F3 |
| 4. D10 restart | Task 11 step 6 |
| 5. Windows CLI ↔ WSL2 daemon (G1) | Task 20 |
| Amendment 2026-11-10: Elasticsearch security switched on over existing data | Task 14 step 7 |

---

## Phase A — Configuration core (pure, no Docker)

### Task 1: Test harness and `.env` document model

**Reads:** SPEC §5.1, §5.2; DEC B2, B3; FC §4; FC §6.

**Files:**
- Create: `tests/Invoke-Tests.ps1`, `scripts/_init.ps1`, `scripts/env-file.ps1`, `.env.example`, `.gitattributes`
- Create: `tests/unit/EnvFile.Tests.ps1`, `tests/fixtures/env/layout1-{postgres,mysql,sqlserver}.env`, `tests/fixtures/env/layout1-edited-crlf.env`, `tests/fixtures/env/bom.env`
- Modify: `.gitignore`

**Interfaces — Produces** (the EnvDocument is `[pscustomobject]@{ Eol; Bom; Entries }`; each entry is `@{ Kind='Pair'|'Raw'; Key; Value; Suffix; Raw }`):
```powershell
ConvertFrom-EnvText [-Text] <string> -> [psobject]
ConvertTo-EnvText [-Document] <psobject> -> [string]
Get-EnvTable [-Document] <psobject> -> [ordered]
Get-EnvValue [-Document] <psobject> [-Key] <string> [[-Default] <string>] -> [string]
Set-EnvValue [-Document] <psobject> [-Key] <string> [-Value] <string> -> [void]   # throws [ArgumentException] naming the key
Remove-EnvKey [-Document] <psobject> [-Key] <string> -> [bool]
Add-MissingEnvKeys [-Document] <psobject> [-Template] <psobject> -> [string[]]
Update-EnvSecrets [-Document] <psobject> [-SecretKeys] <string[]> [[-Generator] <scriptblock>] -> [string[]]
New-RandomPassword [[-Length] <int> = 16] -> [string]
Read-EnvFile [-Path] <string> -> [psobject]
Write-EnvFile [-Document] <psobject> [-Path] <string> -> [void]
$script:SecretKeys = 'DB_PASSWORD','REDIS_PASSWORD','ELASTIC_PASSWORD','KIBANA_PASSWORD'
```

- [ ] **Step 1: Write the failing tests** in `tests/unit/EnvFile.Tests.ps1`. Tag them `Unit`, and dot-source `$PSScriptRoot/../../scripts/_init.ps1` in `BeforeAll`.
  - `round-trips .env.example byte for byte`: `ConvertTo-EnvText (ConvertFrom-EnvText $text) | Should -BeExactly $text`.
  - `round-trips CRLF and keeps the BOM`, over `layout1-edited-crlf.env` and `bom.env` through `Read-EnvFile`/`Write-EnvFile` in `TestDrive:`. The bytes are equal.
  - `strips inline comments from unquoted values`: `COMPOSE_PATH_SEPARATOR` → `;`, `BIND_ADDRESS` → `127.0.0.1`, `COMPOSE_FILE` → `''`.
  - `Set-EnvValue keeps the inline comment`: the line for `BIND_ADDRESS` matches `^BIND_ADDRESS=0\.0\.0\.0\s+# 0\.0\.0\.0 allows access`.
  - `Set-EnvValue appends a missing key as the last line`.
  - `Set-EnvValue rejects values it cannot round-trip`. `-TestCases` with the values `a$b`, `a #b`, `"q"`, `a'b`, and `a` followed by a newline and `b`. Each throws `[System.ArgumentException]` with a message containing the key.
  - `Add-MissingEnvKeys adds only absent keys after their template neighbour`. On `layout1-postgres.env`:
    - the return value contains `START_LOCAL_LAYOUT` and `BIND_ADDRESS`;
    - `DB_PASSWORD` keeps its value;
    - `SEARCH_PROVIDER` appears after `CUSTOM_FRONTEND_URL`.
  - `Update-EnvSecrets fills empty secrets and never rotates`. Two calls with a counter generator: the first returns 4 keys; the second returns `@()` and the values are unchanged.
  - `New-RandomPassword returns 16 alphanumerics`: matches `^[A-Za-z0-9]{16}$`.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit`. Expected: FAIL, `ConvertFrom-EnvText` is not recognized.
- [ ] **Step 3: Implement.**
  - **`.env.example`:** copy SPEC §5.1 verbatim.
  - **Parser:** the compose-go subset: `KEY=VALUE`, an optional `export `, `'…'`, `"…"`, and an unquoted value ending at whitespace followed by `#`. `Suffix` keeps that whitespace and the comment.
  - **`New-RandomPassword`:** `[System.Security.Cryptography.RandomNumberGenerator]::GetInt32`.
  - **`Write-EnvFile`:** UTF-8, writing a BOM only if the file was read with one.
  - **`tests/Invoke-Tests.ps1`:** `param([ValidateSet('Unit','Compose','All')][string]$Tier='Unit')`. Pester 5 `New-PesterConfiguration`, filtering by tag, and `exit $result.FailedCount`.
  - **Fixtures:** the layout-1 files match what `VirtoLocal_create_local_files.ps1` lines 53–82 write today. Use the passwords `pgPass1`, `redisPass1`, `elasticPass1`, `kibanaPass1`. The CRLF file has `PLATFORM_PORT=8091` and a trailing blank line.
  - **`.gitattributes`:** `*.sh`, `*.template`, `*.yml`, `.env.example`, `tests/fixtures/env/*.env` get `eol=lf`; `tests/fixtures/env/layout1-edited-crlf.env` and `bom.env` get `-text`.
  - **`.gitignore`:** add `/logs/`, `/backend/publish/`, `/backend/*-packages.json`, `/frontend/artifact/`, `/docker-compose.platform-modules.yml`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add .env.example .gitattributes .gitignore scripts/_init.ps1 scripts/env-file.ps1 tests/ && git commit -m "Add .env document model and Pester harness"`

### Task 2: `COMPOSE_FILE` catalog and normalization

**Reads:** SPEC §6 (whole); DEC C3, C5, E13, H9; this plan P1, P2, P8, P16.

**Files:** Create `scripts/compose-files.ps1` and `tests/unit/ComposeFiles.Tests.ps1`; modify `scripts/_init.ps1`.

**Interfaces — Consumes:** nothing. **Produces:**
```powershell
$script:ComposeFileCatalog   # ordered @{ Name; Kind='base'|'mode'|'provider'|'feature'|'overlay'|'optin'|'link'; Feature; OverlayOf; Requires=[string[]]; Excludes=[string[]]; Generated=[bool] }
Get-ComposeFileList [-Value] <string> [[-Separator] <string> = ';'] -> [string[]]
ConvertTo-ComposeFileValue [-ComposeFiles] <string[]> [[-Separator] <string> = ';'] -> [string]
Get-ComposeFeatures [-ComposeFiles] <string[]> -> [pscustomobject]   # Provider Platform Elasticsearch Kibana Redis Frontend Https EsLimited Unknown
Resolve-DbProvider [-ComposeFiles] <string[]> -> [string]             # $null if none; [InvalidOperationException] if >1
Update-ComposeFileList [-ComposeFiles] <string[]> [-HasSourceModules] <bool> -> [string[]]
Set-ComposeFeature [-ComposeFiles] <string[]> [-Feature] <string> [-Enabled] <bool> -> [string[]]   # platform|elasticsearch|kibana|redis|frontend|esLimited
Set-ComposeProvider [-ComposeFiles] <string[]> [-Provider] <string> -> [string[]]
Set-ComposeHttps [-ComposeFiles] <string[]> [-Enabled] <bool> -> [string[]]
Get-DefaultComposeFiles [-Provider] <string> [[-Https] <bool> = $true] -> [string[]]
Get-ComposeProjectName [-FolderPath] <string> -> [string]
Get-SolutionVolumeNames [-Prefix] <string> -> [string[]]
Get-SolutionImageNames [-ProjectName] <string> -> [string[]]
```

Canonical order of the catalog. The `docker-compose.` prefix is omitted; links come after the features:
1. `yml`
2. `https.yml`
3. `postgres.yml` | `mysql.yml` | `sqlserver.yml`
4. `platform.yml`, then `platform.https.yml`
5. `elasticsearch.yml`, then `elasticsearch.https.yml`
6. `es-limited.yml`
7. `kibana.yml`, then `kibana.https.yml`
8. `redis.yml`
9. `frontend.yml`, then `frontend.https.yml`
10. `platform-{provider}.yml`
11. `platform-elasticsearch.yml`, then `platform-elasticsearch.https.yml`
12. `platform-redis.yml`
13. `platform-frontend.yml`
14. `platform-modules.yml`
15. `kibana-elasticsearch.yml`, then `kibana-elasticsearch.https.yml`
16. `frontend-hostplatform.yml`

Normalization rules:
- A link is emitted iff all its `Requires` are emitted, plus `-HasSourceModules` for `platform-modules`. `frontend-hostplatform` has `Excludes=platform`.
- An overlay is emitted iff `https.yml` is listed and the file it overlays is emitted.
- Unknown files follow, in their original order.

- [ ] **Step 1: Write the failing tests** (tag `Unit`):
  - `default postgres list is canonical`: `Get-DefaultComposeFiles postgres` equals the catalog entries 1, 2, 3 (postgres), 4, 5, 7, 8, 9, 10 (postgres), 11, 12, 13 and 15 above, with every overlay. That excludes `es-limited`, `platform-modules` and `frontend-hostplatform`.
  - `normalization is idempotent` over 6 `-TestCases`.
  - `adds the platform-elasticsearch link only when both features are listed`.
  - `lists every overlay iff https.yml is listed`. `Set-ComposeHttps $false` removes all `.https.yml`; `$true` restores them.
  - `skipping and re-adding elasticsearch keeps the HTTPS mode`: `Set-ComposeFeature elasticsearch $false`, then `$true`, gives back `elasticsearch.https.yml` and `platform-elasticsearch.https.yml`.
  - `keeps unknown files after built-in files in their order`: `my.override.yml`, `x.yml`.
  - `Resolve-DbProvider`: returns `mysql`; returns `$null` with no provider; throws `InvalidOperationException` when two are listed.
  - `drops kibana with a warning without elasticsearch` (P2). Use `-WarningVariable`.
  - `adds frontend-hostplatform when the frontend is listed without the platform` (P8).
  - `drops es-limited with a warning without elasticsearch`.
  - `Get-ComposeProjectName`: `VirtoLocal` → `virtolocal`; `My Stack.v2` → `mystackv2`. Task 7 cross-checks these against Compose.
  - `Get-SolutionVolumeNames virto` equals exactly 8 names: `virto_postgres_data`, `virto_mysql_data`, `virto_mssql_data`, `virto_cms-content-data`, `virto_modules-data`, `virto_esdata01`, `virto_redisdata`, `virto_certs`.
  - `Get-SolutionImageNames virtolocal` equals `vc-platform:virtolocal-latest`, `vc-frontend:virtolocal-latest`.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/ComposeFiles.Tests.ps1 -Output Detailed"`. Expected: FAIL, the command is not recognized.
- [ ] **Step 3: Implement** per the Interfaces and the rules above. `Get-ComposeProjectName` lowercases, drops `[^a-z0-9_-]`, then trims leading `_` and `-`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/compose-files.ps1 scripts/_init.ps1 tests/unit/ComposeFiles.Tests.ps1 && git commit -m "Add COMPOSE_FILE catalog and normalization"`

### Task 3: Release channels

**Reads:** DEC B8; FU §3; `build-VC-solution.ps1` (whole).

**Files:** Create `scripts/release-channel.ps1`, `tests/unit/ReleaseChannel.Tests.ps1` and `tests/fixtures/json/stable.json` (keys `"0"`–`"16"` without `"13"`, plus `"latest"`; each value is a `package.json` URL); modify `scripts/_init.ps1`.

**Interfaces — Produces:**
```powershell
ConvertTo-ReleaseChannel [-Value] <string> -> [pscustomobject]  # @{ Kind='stable'|'stable-n'|'edge'|'custom'; Number; Normalized; Warnings }, $null if invalid
Test-StableBundleKey [-Number] <int> [-StableJson] <psobject> -> [bool]
Get-BundleSpec [-Channel] <psobject> -> [pscustomobject]       # @{ BundleKey; Edge; FrontendSource='bundle'|'latest-release'|'custom' }
Get-VcBuildInstallArgs [-Channel] <psobject> [-ManifestPath] <string> [-DiscoveryPath] <string> [-ProbingPath] <string> [-Root] <string> -> [string[]]
Get-StableJson -> [psobject]                                    # network: raw.githubusercontent.com/VirtoCommerce/vc-modules/refs/heads/master/bundles/stable.json
Get-BundleFrontendUrl [-BundleKey] <string> [-StableJson] <psobject> -> [string]   # network: that bundle's package.json ThemeB2BVue
Get-LatestFrontendReleaseUrl -> [string]                        # network: api.github.com vc-frontend releases/latest asset
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`):
  - `parses channels`, as `-TestCases`:

    | Input | Kind | Number |
    |-------|------|--------|
    | `stable` | `stable` | – |
    | `stable:16` | `stable-n` | 16 |
    | `edge` | `edge` | – |
    | `custom` | `custom` | – |

  - `latest-stable` gives `stable`, with a warning matching `renamed to 'stable'`.
  - `foo`, `stable:`, `stable:x` and `''` give `$null`.
  - `Test-StableBundleKey`: 13 → `$false`, 16 → `$true` against the fixture.
  - `vc-build args` (exact arrays). The common tail is `--probing-path P --discovery-path D --root R --skip-dependency-solving`.

    | Channel | Arguments before the tail |
    |---------|---------------------------|
    | `stable` | `install` |
    | `stable:16` | `install -v 16` |
    | `edge` | `install -Edge` |
    | `custom` | `install --package-manifest-path M` |

  - `bundle spec`:

    | Channel | BundleKey | FrontendSource |
    |---------|-----------|----------------|
    | `stable` | `latest` | `bundle` |
    | `stable:16` | `16` | `bundle` |
    | `edge` | – | `latest-release` |
    | `custom` | – | `custom` |

- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/ReleaseChannel.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement.** The network functions use `Invoke-RestMethod` and have no unit tests; Task 9 exercises them live.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/release-channel.ps1 scripts/_init.ps1 tests/ && git commit -m "Add release channel parsing and vc-build arguments"`

### Task 4: Parameters → `.env`, run mode and required keys

**Reads:** SPEC §5.2, §8 (the table and its bullets); DEC B1, B4, B5, B6, C2; FC §15; this plan P12.

**Files:** Create `scripts/options.ps1` and `tests/unit/Options.Tests.ps1`; modify `scripts/_init.ps1`.

**Interfaces — Consumes:** Task 1 and Task 2 functions, and `ConvertTo-ReleaseChannel`. **Produces:**
```powershell
Update-EnvFromOptions [-Document] <psobject> [-Bound] <IDictionary> -> [string[]]   # returns warnings; rewrites COMPOSE_FILE through Update-ComposeFileList; on a mode change applies P17 to FRONTEND_PORT
Test-NonInteractive [-Switch] <bool> [-InputRedirected] <bool> [-CiValue] <string> -> [bool]
Get-MissingRequiredKeys [-EnvValues] <IDictionary> -> [string[]]
Request-RequiredEnvKeys [-Document] <psobject> [-NonInteractive] <bool> -> [string[]]   # prompts once per key; returns the keys still missing
Read-YesNo [-Prompt] <string> [-Default] <bool> [-NonInteractive] <bool> -> [bool]
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`). Start each from a document of `.env.example` with `COMPOSE_FILE` set to the default postgres list.
  - `-dbProvider mysql` replaces `postgres.yml` and `platform-postgres.yml` with their mysql counterparts.
  - `-allowInsecureHttp` removes every `.https.yml`; `-allowInsecureHttp:$false` restores them.
  - `FRONTEND_PORT follows the mode default` (P17), as `-TestCases`:

    | Starting mode and port | Switch | Resulting port |
    |------------------------|--------|----------------|
    | HTTPS, `443` | `-allowInsecureHttp` | `80` |
    | HTTP, `80` | `-allowInsecureHttp:$false` | `443` |
    | HTTPS, `8443` | `-allowInsecureHttp` | `8443` |
    | HTTP, `80` | `-allowInsecureHttp` (no mode change) | `80` |

  - `-skipKibana` removes `kibana.yml`, `kibana.https.yml`, `kibana-elasticsearch.yml` and `kibana-elasticsearch.https.yml`; `-skipKibana:$false` restores them.
  - `-skipPlatform` with `PLATFORM_SOURCE_PATH=/src/p` writes `SKIP_PLATFORM=true` and leaves `COMPOSE_FILE` unchanged. Without the path, it removes the platform files and adds `frontend-hostplatform.yml`.
  - `-releaseChannel latest-stable` writes `RELEASE_CHANNEL=stable` and returns 1 warning.
  - `-vcSolutionVersion edge` writes `RELEASE_CHANNEL=edge`; `-elasticsearchVersion 9.1.0` writes `STACK_VERSION=9.1.0`.
  - `-branch release/2.0` writes `START_LOCAL_REF=release/2.0`.
  - `per-run switches never persist`: after binding `skipSampleData`, `nonInteractive` and `keepData`, `ConvertTo-EnvText` is unchanged.
  - `Test-NonInteractive`:
    - `$false, $false, ''` → `$false`;
    - `$true, $false, ''` → `$true`;
    - `$false, $true, ''` → `$true`;
    - `$false, $false, 'true'` → `$true`.
  - `Get-MissingRequiredKeys`:
    - `.env.example` → `COMPOSE_FILE`, `RELEASE_CHANNEL`;
    - with `RELEASE_CHANNEL=custom` → `CUSTOM_PACKAGES_JSON`.
  - `Request-RequiredEnvKeys -NonInteractive $true` returns the missing keys and never calls `Read-Host`. Use `Mock Read-Host` and `Should -Invoke -Times 0`.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/Options.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement** per the Interfaces.
  - `Request-RequiredEnvKeys` asks for `COMPOSE_FILE` as the DB provider choice (1 postgres default, 2 mysql, 3 sqlserver). It writes `Get-DefaultComposeFiles <provider> -Https $true`.
  - `RELEASE_CHANNEL` defaults to `stable`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/options.ps1 scripts/_init.ps1 tests/unit/Options.Tests.ps1 && git commit -m "Map script parameters onto .env"`

### Task 5: Migration from layout 1 to layout 2

**Reads:** SPEC §9; DEC F1, F2, D3, D6, D7, D9, C6; the "Compatibility surface" section of DEC.

**Files:** Create `scripts/migrate.ps1`, `tests/unit/Migrate.Tests.ps1`, `tests/fixtures/env/layout1-no-provider.env` and `layout1-bad-provider.env`; modify `scripts/_init.ps1`.

**Interfaces — Consumes:** Tasks 1 and 2. **Produces:**
```powershell
Get-EnvLayout [-Document] <psobject> -> [int]                   # missing START_LOCAL_LAYOUT => 1
Convert-EnvToLayout2 [-Document] <psobject> [-Template] <psobject> -> [pscustomobject]   # @{ Document; Changes=[string[]]; Notes=[string[]] }
Get-LayoutMigrationImageRetags [-ProjectName] <string> -> [pscustomobject[]]   # @{ From; To }
Test-DockerImage [-Name] <string> -> [bool]
Invoke-DockerTag [-Source] <string> [-Target] <string> -> [void]
Invoke-StartLocalMigration [-SolutionFolder] <string> -> [pscustomobject]       # $null when there is no .env
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`):
  - **`maps DB_PROVIDER to COMPOSE_FILE in HTTP mode`.** For each layout-1 provider fixture, `COMPOSE_FILE` equals `ConvertTo-ComposeFileValue (Get-DefaultComposeFiles <provider> -Https $false)`.
  - **`keeps every existing value`:** the four secrets, `PLATFORM_PORT=8091` (CRLF fixture), `FRONTEND_PORT=80` and `STACK_VERSION=8.18.0` are unchanged.
  - **`adds keys`:** `VOLUME_PREFIX=virto`, `BIND_ADDRESS=127.0.0.1`, `SEARCH_PROVIDER=ElasticSearch8`, `COMPOSE_PATH_SEPARATOR=;`, `START_LOCAL_LAYOUT=2`.
  - **`removes keys`:** `DB_PROVIDER`, `ES_CLUSTER_NAME`, `ES_LICENSE`.
  - **`is idempotent`:** a second call returns empty `Changes`.
  - **`keeps CRLF`:** the CRLF fixture's `Eol` is unchanged.
  - **`Notes` explain the bind change:** they contain `BIND_ADDRESS=0.0.0.0`.
  - **`fails on a missing or bad provider`:** both fixtures throw `InvalidOperationException` with a message containing `DB_PROVIDER`.
  - **`retag pairs`:** `Get-LayoutMigrationImageRetags virtolocal` gives `vc-platform:local-latest → vc-platform:virtolocal-latest` and the same for `vc-frontend`.
  - **`wrapper retags only when the source exists and the target does not`:**
    - `Mock Test-DockerImage` returns `$true` for `*:local-latest` and `$false` otherwise; `Should -Invoke Invoke-DockerTag -Times 2`.
    - When the target already exists: `-Times 0`.
  - **`wrapper on a folder without .env returns $null`.**
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/Migrate.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `Convert-EnvToLayout2` does SPEC §9 steps 1–4 and 6, then calls `Add-MissingEnvKeys`.
  - The wrapper reads `.env`, converts it, writes it only when `Changes` is non-empty, retags, and prints `Changes` and `Notes`.
  - The project name comes from `Get-ComposeProjectName $SolutionFolder`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/migrate.ps1 scripts/_init.ps1 tests/ && git commit -m "Add layout 1 to 2 migration"`

### Task 6: Platform settings function

**Reads:** SPEC §5.3, §7.2 (*Config*), §10 (*The platform trusts Elasticsearch*); DEC C4, H5, E11, D6, D8; FU §1; FC §9, §18; the three `docker-compose.{postgres,mysql,sqlserver}.yml` files (today's connection strings).

**Files:** Create `scripts/settings-file.ps1` and `tests/unit/SettingsFile.Tests.ps1`; modify `scripts/_init.ps1`.

**Interfaces — Consumes:** `Get-ComposeFeatures`, `Resolve-DbProvider`. **Produces:**
```powershell
Get-DbSettings [-Provider] <string> [-EnvValues] <IDictionary> [-Topology] <string> -> [ordered]   # 'Container'|'Host'
Get-PlatformSettings [-EnvValues] <IDictionary> [-ComposeFiles] <string[]> [-Topology] <string> [[-CaFingerprint] <string>] -> [ordered]   # flat ':' keys
ConvertTo-SettingsJson [-Flat] <IDictionary> -> [string]           # nested by ':'
Get-SettingsFilePath [-PlatformPath] <string> [-Kind] <string> -> [string]   # 'checkout'|'prebuilt'
Get-ContainerOnlyKeys -> [string[]]   # ASPNETCORE_URLS, Kestrel:Certificates:Default:Path, Kestrel:Certificates:Default:KeyPath, SEARCH_PROVIDER
Get-HostOnlyKeys -> [string[]]        # Kestrel:Endpoints:Main:Url, Search:<provider>:CertificateFingerprint
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`). Start from `.env.example` plus secrets `pg1`/`r1`/`e1`/`k1`, with the default postgres list in HTTP mode.
  - **`Container postgres HTTP`** equals exactly, in order:

    | Key | Value |
    |-----|-------|
    | `DatabaseProvider` | `PostgreSql` |
    | `ConnectionStrings:VirtoCommerce` | `User ID=postgres;Password=pg1;Host=vc-db;Port=5432;Database=VirtoCommerce3` |
    | `VirtoCommerce:AllowInsecureHttp` | `true` |
    | `VirtoCommerce:Hangfire:JobStorageType` | `Memory` |
    | `Assets:FileSystem:PublicUrl` | `http://localhost:8090/assets/` |
    | `Content:FileSystem:PublicUrl` | `http://localhost:8090/cms-content/` |
    | `Search:Provider` | `ElasticSearch8` |
    | `Search:ElasticSearch8:Server` | `http://es:9200` |
    | `Search:ElasticSearch8:User` | `elastic` |
    | `Search:ElasticSearch8:Key` | `e1` |
    | `ConnectionStrings:RedisConnectionString` | `redis:6379,password=r1` |

  - **`Host topology`:**
    - `Host=localhost;Port=5432` from `PGSQL_PORT`, `http://localhost:9200` from `ES_PORT`, `localhost:6379,password=r1`;
    - plus `Kestrel:Endpoints:Main:Url=http://127.0.0.1:8090` (P9).
  - **`mysql`:** `MySql`, `Server=vc-db;Port=3306;Database=VirtoCommerce3;User=root;Password=pg1`.
  - **`sqlserver`:** `SqlServer`, `Server=vc-db,1433;Database=VirtoCommerce3;User Id=sa;Password=pg1;TrustServerCertificate=True`. In the Host topology the server is `localhost,1433`.
  - **`omits Search keys without elasticsearch and the Redis key without redis`.**
  - **`HTTPS mode`:** `AllowInsecureHttp=false`, `https://` public URLs, and Search Server `https://es:9200` (Container) or `https://localhost:9200` (Host).
  - **`SEARCH_PROVIDER=ElasticSearch9 renames the Search keys`.**
  - **`emits CertificateFingerprint only for Host`.**
  - **`ConvertTo-SettingsJson nests`:** `(ConvertFrom-Json $json).ConnectionStrings.VirtoCommerce` equals the flat value.
  - **`settings file path`:**
    - checkout → `<p>/src/VirtoCommerce.Platform.Web/VirtoCommerce.Platform.Web.settings.json`;
    - prebuilt → `<p>/VirtoCommerce.Platform.Web.settings.json`.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/SettingsFile.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement** per the Interfaces. The provider comes from `Resolve-DbProvider`. The scheme comes from the `Https` feature. The bind host comes from `BIND_ADDRESS`, defaulting to `127.0.0.1`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/settings-file.ps1 scripts/_init.ps1 tests/unit/SettingsFile.Tests.ps1 && git commit -m "Add platform settings function"`

## Phase B — HTTP-mode Docker stack

### Task 7: Base, database, search and cache compose files

**Reads:**
- SPEC §6 (rows `docker-compose.yml`, `{postgres,mysql,sqlserver}`, `elasticsearch`, `kibana`, `redis`, `es-limited`; *Further rules*);
- DEC D1, D2, D5, D6, D9, D10, C6, H10;
- FC §4, §5, §7; FC *Amendments* (Compose interpolation);
- today's `docker-compose.yml` and the three provider files.

**Files:**
- Modify: `docker-compose.yml`, `docker-compose.{postgres,mysql,sqlserver}.yml`
- Create: `docker-compose.elasticsearch.yml`, `docker-compose.es-limited.yml`, `docker-compose.kibana.yml`, `docker-compose.kibana-elasticsearch.yml`, `docker-compose.redis.yml`
- Create: `scripts/payload.ps1`, `tests/support/TestHelpers.ps1`, `tests/compose/ComposeConfig.Tests.ps1`, `tests/unit/Payload.Tests.ps1`

**Interfaces — Produces:**
```powershell
Get-PayloadAllowlist -> [string[]]   # install.ps1 build.ps1 start.ps1 stop.ps1 remove.ps1 .env.example docker-compose*.yml scripts/ backend/ frontend/
Copy-Payload [-Root] <string> [-Destination] <string> -> [void]   # never writes .env; skips allowlisted files that don't exist yet
# tests/support/TestHelpers.ps1
New-ComposeFixtureFolder [-ComposeFiles] <string[]> [[-EnvOverrides] <hashtable>] [[-FolderName] <string> = 'fixture'] -> [string]   # yml files + .env from .env.example, secrets filled
Invoke-ComposeConfigJson [-Folder] <string> -> [psobject]   # docker compose config --format json; uses $env:SL_COMPOSE_BINARY when set
New-ScratchSolution [[-Name] <string>] -> [string]          # Copy-Payload into $TMPDIR/sl-<name>
```

Content:
- **`docker-compose.yml`:** only `networks: { virto: {} }`. Each feature declares its own volume with a `name:`.
- **`vc-db` healthchecks** (10s/10s/120):
  - postgres: `pg_isready -h 127.0.0.1 -U postgres -d VirtoCommerce3`;
  - mysql: `mysqladmin ping -h 127.0.0.1 -uroot -p"$$MYSQL_ROOT_PASSWORD" --silent`;
  - sqlserver: `/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$$MSSQL_SA_PASSWORD" -Q "SELECT 1" -b`.
- **`es`:** the environment of today's `docker-compose.yml`, with these changes:
  - the cluster name `elasticsearch` and the license `basic` are fixed (C6);
  - `EnableCompatibilityMode` is gone;
  - healthcheck `curl -fs "http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=5s"`;
  - `mem_limit: ${ES_MEM_LIMIT:-1g}`;
  - `restart: unless-stopped`.
- **`es-limited`:** `discovery.type=single-node`, `bootstrap.memory_lock=false`, `cluster.initial_master_nodes=` (P11), and `ulimits: !reset {}`.
- **`kibana`:** image, port and healthcheck `curl -fs http://localhost:5601/api/status`.
- **`kibana-elasticsearch`:** `ELASTICSEARCH_HOSTS=http://es:9200`, `ELASTICSEARCH_USERNAME=kibana_system`, `ELASTICSEARCH_PASSWORD`, `XPACK_SECURITY_ENABLED=false`, and `depends_on es` healthy.
- **`redis`:** `redis:alpine` with `--requirepass`, no volume, and healthcheck `redis-cli -a "$$REDIS_PASSWORD" --no-auth-warning ping | grep -q PONG`. The password is passed as `REDIS_PASSWORD` in the environment.

- [ ] **Step 1: Write the failing tests:**
  - `Payload.Tests.ps1` (tag `Unit`):
    - `allowlist excludes docs, tests, .github and the four old-named scripts`;
    - `Copy-Payload never touches an existing .env`: a `.env` sentinel in `TestDrive:` is byte-equal afterwards.
  - `ComposeConfig.Tests.ps1` (tag `Compose`; skip when `docker` is not found). `-TestCases` over 3 providers × Elasticsearch on/off × Kibana (only with Elasticsearch) × Redis on/off × es-limited, all in HTTP mode, built through `Update-ComposeFileList`:
    - `config succeeds`;
    - `every published port binds 127.0.0.1`;
    - `volume names use VOLUME_PREFIX`: `virto_postgres_data` with `VOLUME_PREFIX=virto`, and `fixture_postgres_data` when it is empty;
    - `long-running services restart unless-stopped`;
    - `es-limited sets single-node and drops memlock`;
    - `vc-db has a healthcheck`;
    - `project name matches Get-ComposeProjectName` for the folder names `VirtoLocal` and `My Stack.v2`;
    - `every docker-compose*.yml in the repo is in the catalog`.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier All`. Expected: FAIL, the files and `New-ComposeFixtureFolder` are missing.
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Live checks.** For each provider, in a `New-ScratchSolution` folder with `COMPOSE_FILE` = data services plus `es-limited`, run `docker compose up -d --wait`. Expected: every service `healthy`.
  - **V11:** on a fresh Postgres volume, `vc-db` never reports `healthy` before `psql -h 127.0.0.1` succeeds.
  - **V6:** `es` is healthy with `es-limited`. If ES exits with `not allowed when [discovery.type] is set to [single-node]`, **stop and report**.
  - Tear down with `docker compose down -v`.
- [ ] **Step 6: Compose v2.18.0 (SPEC §15 #1).**
  1. Download `https://github.com/docker/compose/releases/download/v2.18.0/docker-compose-linux-x86_64` to `$TMPDIR`.
  2. `chmod +x` it, then run the `Compose` tier with `$env:SL_COMPOSE_BINARY` set to that file.

  Expected: PASS. **Stop and report** on failure (D4's minimum is wrong).
- [ ] **Step 7: Commit:** `git add docker-compose*.yml scripts/payload.ps1 tests/ && git commit -m "Split data, search and cache services into feature files"`

### Task 8: Platform image, platform and storefront compose files (HTTP)

**Reads:**
- SPEC §5.3, §6 (rows `platform`, `platform-<feature>`, `frontend`, `frontend-hostplatform`), §12 (drift test);
- DEC C4, C5, D3, D5, D6, H7, H8;
- this plan P1–P5, P8;
- today's `frontend/nginx.conf`, `frontend/Dockerfile`, and the vc-docker Dockerfile (`raw.githubusercontent.com/VirtoCommerce/vc-docker/feat/net10/linux/platform/Dockerfile`).

**Files:**
- Create: `backend/Dockerfile`, `backend/entrypoint.sh`, `docker-compose.platform.yml`
- Create: `docker-compose.platform-{postgres,mysql,sqlserver}.yml`, `docker-compose.platform-elasticsearch.yml`, `docker-compose.platform-redis.yml`, `docker-compose.platform-frontend.yml`
- Create: `docker-compose.frontend.yml`, `docker-compose.frontend-hostplatform.yml`
- Create: `frontend/nginx/http/default.conf.template`, `frontend/nginx/common/snippets/storefront.conf.template`
- Modify: `frontend/Dockerfile`
- Delete: `frontend/nginx.conf`
- Create: `tests/compose/SettingsDrift.Tests.ps1`
- Modify: `tests/compose/ComposeConfig.Tests.ps1`

Content:
- **`platform.yml`:**
  - port `${PLATFORM_PORT}:8080`;
  - environment `ASPNETCORE_URLS=http://+:8080`, `VirtoCommerce__AllowInsecureHttp=true`, `VirtoCommerce__Hangfire__JobStorageType=Memory`, and the two `PublicUrl`s;
  - the volumes `cms-content-data` and `modules-data` at today's mount points;
  - healthcheck `curl -fs http://localhost:8080/health`.
- **`platform-<provider>`:** P1, with the connection strings of Task 6 written with `__` keys.
- **`platform-elasticsearch`:** `Search__Provider=${SEARCH_PROVIDER}`, `SEARCH_PROVIDER=${SEARCH_PROVIDER}`, `Search__${SEARCH_PROVIDER}__{Server,User,Key}`, and `depends_on es`.
- **`platform-redis`:** `ConnectionStrings__RedisConnectionString=redis:6379,password=${REDIS_PASSWORD}` and `depends_on redis`.
- **`platform-frontend`:** `vc-frontend` with `depends_on vc-platform-web` healthy and `PLATFORM_UPSTREAM=vc-platform-web:8080`.
- **`frontend.yml`:** port `${FRONTEND_PORT}:8080`, `NGINX_ENVSUBST_TEMPLATE_DIR=/etc/nginx/templates-http`, `NGINX_ENVSUBST_FILTER=^PLATFORM_`, `PLATFORM_SCHEME=http`.
- **`frontend-hostplatform`:** `extra_hosts: ["host.docker.internal:host-gateway"]` and `PLATFORM_UPSTREAM=host.docker.internal:${PLATFORM_PORT}`.
- **nginx templates:** the snippet holds today's `location` blocks with `proxy_pass ${PLATFORM_SCHEME}://${PLATFORM_UPSTREAM};`. The http template is `listen 8080;` plus `include /etc/nginx/conf.d/snippets/storefront.conf;`.
- **`frontend/Dockerfile`:** copies `nginx/http/` to `/etc/nginx/templates-http/` and `nginx/common/` to `/etc/nginx/templates-http/snippets/`, and `EXPOSE 8080`.
- **`backend/entrypoint.sh`:** `#!/bin/sh`, `set -eu`, `exec "$@"`.

- [ ] **Step 1: Write the failing tests** (tag `Compose`):
  - **Drift test.** `SettingsDrift.Tests.ps1`, over 3 providers × Elasticsearch × Redis in HTTP mode:
    1. Normalize the keys of `services.vc-platform-web.environment` (`__` → `:`).
    2. Every key of `Get-PlatformSettings -Topology Container` exists in the compose environment with an equal value.
    3. Every compose key outside `Get-ContainerOnlyKeys` exists in the function's output.
  - **Matrix additions:**
    - `platform depends_on is exactly the implied set, all service_healthy`;
    - `image tags are vc-platform:<project>-latest and vc-frontend:<project>-latest`;
    - `frontend without platform gets host.docker.internal upstream and the host-gateway extra_host`;
    - `platform-modules is never listed without source modules`.
  - **V12:** the merged `depends_on` of a platform with all four links contains `vc-db`, `es` and `redis`, each `service_healthy`.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Compose`. Expected: FAIL.
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add backend/ frontend/ docker-compose*.yml tests/ && git commit -m "Add platform and storefront compose files and drift test"`

### Task 9: `build.ps1` and the Compose v2 helper

**Reads:** SPEC §8 (table, *Obsolete parameters*), §8.1 (*build*); DEC B1, B8, D4; FC §15; `build-VC-solution.ps1`; CIR *Recommendations* item 4 (no change to `--no-cache` now).

**Files:** Create `build.ps1` and `tests/unit/ComposeHelper.Tests.ps1`; modify `scripts/docker-compose-helper.ps1`.

**Interfaces — Produces:**
```powershell
Invoke-DockerCompose [args]              # v2 only; throws [System.InvalidOperationException] when 'docker compose' is missing
Get-ComposeVersion -> [string]           # docker compose version --short
Test-ComposeVersion [-Version] <string> [[-Minimum] <string> = '2.18.0'] -> [bool]
# build.ps1 param: [string]$solutionFolder=$PSScriptRoot, [string]$releaseChannel, [string]$customPackagesJson, [string]$customFrontendUrl,
#   [Obsolete("Use -releaseChannel")][string]$vcSolutionVersion, [bool]$skipSampleData=$false, [switch]$nonInteractive
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`). `Test-ComposeVersion` with `-TestCases`:
  - `2.18.0` → `$true`;
  - `2.17.3` → `$false`;
  - `v2.40.3` → `$true`;
  - `5.6.0` → `$true`;
  - `2.18.0-desktop.1` → `$true`.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/ComposeHelper.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement `build.ps1`**, in this order:
  1. `Push-Location`, migrate, `Update-EnvFromOptions`, `Request-RequiredEnvKeys`. Exit 1 naming the missing keys.
  2. Parse the channel. For `stable-n`, check `Test-StableBundleKey` against `Get-StableJson` and fail when the key is unknown.
  3. When `Get-ComposeFeatures().Platform`: run `vc-build` with `Get-VcBuildInstallArgs` into `backend/publish`, then `docker build --no-cache -t vc-platform:<project>-latest backend`.
  4. When `Frontend`: fetch the storefront ZIP for the channel, then `docker build -t vc-frontend:<project>-latest frontend`.
  5. Ask `Read-YesNo "Start now?" $true`, then call `start.ps1` with only `-skipSampleData` and `-nonInteractive`.

  The `custom` manifest handling moves over from today's script unchanged.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Live check.** In a scratch solution with `COMPOSE_FILE` set to the default postgres list in HTTP mode and `RELEASE_CHANNEL=stable`, run `./build.ps1 -nonInteractive`.
  - Expected: `docker image inspect vc-platform:sl-<name>-latest` and `vc-frontend:…` both exit 0.
  - The trailing start call reports that `start.ps1` is missing until Task 11.
- [ ] **Step 6: Commit:** `git add build.ps1 scripts/docker-compose-helper.ps1 tests/unit/ComposeHelper.Tests.ps1 && git commit -m "Add build.ps1 on the .env-first layout"`

### Task 10: Platform API helpers and admin password

**Reads:** SPEC §8 (*Admin password*); DEC C1; this plan P10; `scripts/auth-helper.ps1`, `watch-url-up.ps1`, `check-installed-modules.ps1`, `setup-sampledata.ps1`.

**Files:**
- Create: `scripts/admin-password.ps1`, `tests/unit/AdminPassword.Tests.ps1`
- Modify: `scripts/auth-helper.ps1`, `scripts/watch-url-up.ps1`, `scripts/check-installed-modules.ps1`, `scripts/setup-sampledata.ps1`, `scripts/_init.ps1`

**Interfaces — Produces:**
```powershell
Get-AuthToken [-AppAuthUrl] <string> [-Username] <string> [-Password] <string> -> [string]   # $null on failure (was: exit 1)
Watch-Url-Up [-ApiUrl] <string> [-TimeoutMinutes] <int> [-RetrySeconds] <int> [-WaitSeconds] <int> [[-OnFailureLog] <scriptblock>] -> [bool]   # -SkipCertificateCheck inside
Get-AdminLoginCandidates [[-AdminPassword] <string>] -> [string[]]
Get-AdminToken [-ApiUrl] <string> [[-AdminPassword] <string>] -> [string]     # $null when no candidate works
Set-AdminPassword [-ApiUrl] <string> [-Token] <string> [-NewPassword] <string> -> [bool]
```

The two script helpers `check-installed-modules.ps1` and `setup-sampledata.ps1` take `-AdminPassword` in place of `-Password`, and lose `-ContainerId`. `check-installed-modules.ps1` also loses its inline copy of `Watch-Url-Up` (its lines 61–125).

`Watch-Url-Up` drops its `-ContainerId` parameter, its `docker logs` call and its forced `docker restart` every 9th attempt. Restarts now come from the restart policy and healthchecks (D5, D10), and a source platform has no container.

- [ ] **Step 1: Write the failing tests** (tag `Unit`):
  - `candidates`: `s3cret` → `@('s3cret','store')`; `''` → `@('store')`; `store` → `@('store')`.
  - `Get-AdminToken falls back to store`: `Mock Get-AuthToken` returns `$null` for `s3cret` and `tok` for `store`, so the result is `tok`.
  - `Set-AdminPassword posts the reset`: `Mock Invoke-RestMethod`, then assert:
    - URI `<api>/api/platform/security/users/admin/resetpassword`, method `Post`;
    - the body JSON has `newPassword` and `forcePasswordChangeOnNextSignIn = $false`.
  - `Watch-Url-Up returns false on timeout and calls OnFailureLog`: `Mock Invoke-WebRequest { throw }`, with 0-second waits.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/AdminPassword.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement** per the Interfaces.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/ tests/unit/AdminPassword.Tests.ps1 && git commit -m "Add admin password helpers and drop helper exits"`

### Task 11: Preflight, `start.ps1` and `stop.ps1` (Docker platform)

**Reads:** SPEC §8 (table), §8.1 (*start* steps 1–3, 5, 7–9; *stop*), §11; DEC B6, C1, D10; `start-VC-solution.ps1`; this plan Review Focus 3.

**Files:** Create `scripts/preflight.ps1`, `start.ps1`, `stop.ps1` and `tests/unit/Preflight.Tests.ps1`; modify `scripts/_init.ps1`.

**Interfaces — Produces:**
```powershell
Get-RequiredPorts [-EnvValues] <IDictionary> [-ComposeFiles] <string[]> [[-ExcludePorts] <int[]>] -> [pscustomobject[]]   # @{ Key; Port }
Get-ServiceUrls [-EnvValues] <IDictionary> [-ComposeFiles] <string[]> -> [pscustomobject[]]                           # @{ Name; Url }
Get-ProjectPublishedPorts -> [int[]]      # docker compose ps --format json, publishers' PublishedPort
Test-DockerRunning -> [bool]
Test-PortInUse [-Port] <int> -> [bool]    # moved from start-VC-solution.ps1
Invoke-Preflight [-EnvValues] <IDictionary> [-ComposeFiles] <string[]> [-NonInteractive] <bool> -> [string[]]   # errors, each naming its fix
# start.ps1 param: $solutionFolder=$PSScriptRoot, [ValidateSet('postgres','mysql','sqlserver')]$dbProvider, [switch]$allowInsecureHttp,
#   # --- Skip parts ---  [switch]$skipPlatform, [switch]$skipFrontend, [switch]$skipElasticsearch, [switch]$skipKibana, [switch]$skipRedis,
#   [bool]$skipSampleData=$true, [switch]$nonInteractive
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`):
  - `required ports follow COMPOSE_FILE`: postgres + platform + redis → `PGSQL_PORT`, `PLATFORM_PORT`, `REDIS_PORT` only.
  - `a source platform still requires PLATFORM_PORT`: no platform file and `PLATFORM_SOURCE_PATH` set.
  - `own published ports are excluded`: `-ExcludePorts 8090` drops `PLATFORM_PORT`.
  - `service URLs`:
    - HTTP: `Platform` is `http://localhost:8090`;
    - HTTPS: `https://localhost:8090` and `Storefront` is `https://localhost:443`;
    - `Kibana` appears only when listed.
  - `Invoke-Preflight reports an old Compose`: `Mock Get-ComposeVersion { '2.17.0' }`, and the errors contain `2.18.0`.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/Preflight.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement `start.ps1`.**
  - The steps: migrate → `Update-EnvFromOptions` → preflight (exit 1 printing the errors) → write the normalized `COMPOSE_FILE` → `docker compose up -d --remove-orphans`.
  - Unless the platform is skipped:
    1. `check-installed-modules.ps1`, with the log callback `{ docker compose logs --tail 50 vc-platform-web }`.
    2. Non-interactive only: if `ADMIN_PASSWORD` is empty, generate it with `New-RandomPassword` and save it. Then `Get-AdminToken` and `Set-AdminPassword`.
    3. Sample data, unless `-skipSampleData`.
  - Finally, print `Get-ServiceUrls`.
  - `stop.ps1` migrates, then runs `docker compose down --remove-orphans`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: HTTP smoke.** In the Task 9 scratch folder:
  1. Run `./start.ps1 -nonInteractive -skipSampleData $false`. Expected:
     - `curl -fs http://localhost:8090/health` → 200;
     - `ADMIN_PASSWORD` is non-empty in `.env`, and a token is issued with it;
     - at least 23 modules are installed.
  2. Run `./start.ps1` again. Expected: no port errors.
  3. **V9:** `docker compose exec vc-platform-web sh -c 'command -v curl'` succeeds.
- [ ] **Step 6: D10 (SPEC §15 #4).**
  1. `docker compose stop vc-db`, then `docker restart <platform container>`.
  2. Poll `docker inspect -f '{{.State.Status}} {{.RestartCount}}'` for 2 minutes. Expected: the platform exits and `RestartCount` grows.
  3. `docker compose start vc-db`. Expected: the platform becomes `healthy`.

  **Stop and report** if the platform hangs instead of exiting.
- [ ] **Step 7: Commit:** `git add start.ps1 stop.ps1 scripts/ tests/unit/Preflight.Tests.ps1 && git commit -m "Add start.ps1, stop.ps1 and preflight checks"`

### Task 12: `remove.ps1` and the old-name guards

**Reads:** SPEC §4.1, §8.1 (*remove*); DEC A5, F6; FC §6; this plan P13; `remove-VC-solution.ps1`.

**Files:**
- Create: `remove.ps1`, `tests/unit/Remove.Tests.ps1`, `tests/unit/Guards.Tests.ps1`
- Modify (each becomes a guard): `build-VC-solution.ps1`, `start-VC-solution.ps1`, `stop-VC-solution.ps1`, `remove-VC-solution.ps1`

**Interfaces — Produces:**
```powershell
Test-RemovableFolder [-Folder] <string> -> [bool]        # $false when <Folder>/.git exists
Get-RemovalPlan [-Folder] <string> [-KeepData] <bool> -> [pscustomobject]   # @{ DownArgs; Volumes; Images; DeletePaths }
# remove.ps1 param: $solutionFolder=$PSScriptRoot, [switch]$keepData, [switch]$nonInteractive
# each guard: param([Parameter(ValueFromRemainingArguments)]$remaining); reads only $PSScriptRoot/.env; dot-sources nothing
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`):
  - `refuses a git checkout`.
  - `full plan`: `DownArgs` = `down -v --remove-orphans`, the 8 `Get-SolutionVolumeNames` for the folder's `VOLUME_PREFIX`, both images, and `DeletePaths` = the folder.
  - `keepData plan`: `DownArgs` = `down --remove-orphans`, `Volumes` empty, and `DeletePaths` = every child except `.env`.
  - Guards, run as `pwsh -NoProfile -File <copy in TestDrive>` with arbitrary arguments (`-targetFolder X -skipSampleData $false`):
    - **no `.env`, or a layout-1 `.env`:** exit code ≠ 0, and the output contains `release/1.0`, `install.ps1` and `passwords`;
    - **`START_LOCAL_LAYOUT=2`:** the output contains `renamed` plus the new name (`start.ps1`, …), and the exit code is 1;
    - **binding:** never a parameter binding error.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/Remove.Tests.ps1,tests/unit/Guards.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **`remove.ps1`** migrates first, so a layout-1 folder gets `VOLUME_PREFIX=virto`. Then it executes the plan. A volume or image that is already gone only warns, as today.
  - **Guard message**, the three points of A5:
    1. the old layout: `release/1.0`'s `VirtoLocal_create_local_files.ps1`, or `-branch release/1.0`;
    2. `install.ps1` migrates this folder;
    3. an old installer run here has already regenerated the passwords (FC §6).
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Live check.**
  1. `./remove.ps1 -keepData` in the scratch folder: the volumes still exist (`docker volume ls`), and `.env` is the only file left.
  2. Restore the payload with `Copy-Payload` and run `./start.ps1`: the data is back.
  3. `./remove.ps1`: the volumes and the folder are gone.
- [ ] **Step 6: Commit:** `git add remove.ps1 build-VC-solution.ps1 start-VC-solution.ps1 stop-VC-solution.ps1 remove-VC-solution.ps1 tests/ && git commit -m "Add remove.ps1 and turn old scripts into guards"`

## Phase C — HTTPS

### Task 13: Elasticsearch and Kibana over TLS

**Reads:**
- SPEC §6 (rows `https`, `elasticsearch.https`, `kibana.https`, `platform-elasticsearch.https`), §10;
- DEC E3, E9, E11, E13;
- FC §16, FC *Amendments* (CA fingerprint inside the ES image);
- FU §2;
- Elastic's official compose (`elastic/elasticsearch` 8.19 `docs/reference/setup/install/docker/docker-compose.yml`).

**Files:**
- Create: `docker-compose.https.yml`, `docker-compose.elasticsearch.https.yml`, `docker-compose.kibana.https.yml`, `docker-compose.kibana-elasticsearch.https.yml`, `docker-compose.platform-elasticsearch.https.yml`
- Modify: `tests/compose/ComposeConfig.Tests.ps1`

Content:
- **`https.yml`:** the volume `certs`, named `${VOLUME_PREFIX:-${COMPOSE_PROJECT_NAME}}_certs`.
- **`es-setup`:** Elastic's setup container cut to one node.
  - certutil writes the CA and the `es` and `kibana` certificates. Each has DNS names `<name>` and `localhost`, and IP `127.0.0.1`.
  - It writes `ca/ca.fingerprint` through `sed '/-----/d' ca.crt | base64 -d | sha256sum | cut -d' ' -f1`.
  - It sets the `kibana_system` password.
  - Healthcheck: the files `ca/ca.crt`, `es/es.crt`, `kibana/kibana.crt` and `ca/ca.fingerprint` exist.
- **`es` overlay:**
  - `depends_on es-setup` healthy;
  - security and HTTP/transport TLS on, by key;
  - the certificates at `/usr/share/elasticsearch/config/certs`;
  - healthcheck `curl -fs --cacert config/certs/ca/ca.crt -u elastic:$$ELASTIC_PASSWORD https://localhost:9200/_cluster/health?wait_for_status=yellow`.
- **`kibana.https`:** `SERVER_SSL_ENABLED=true` with the `kibana` cert and key, the certificates at `/usr/share/kibana/config/certs`, and healthcheck `curl -fsk https://localhost:5601/api/status`.
- **`kibana-elasticsearch.https`:** `ELASTICSEARCH_HOSTS=https://es:9200` and `ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES=config/certs/ca/ca.crt`.
- **`platform-elasticsearch.https`:** `Search__${SEARCH_PROVIDER}__Server=https://es:9200`, and the `certs` volume `:ro` at `/certs`.

- [ ] **Step 1: Write the failing tests** (tag `Compose`). Extend the matrix to HTTPS; the HTTPS cases assert:
  - no `http://` in `es` or `kibana` healthchecks or URLs;
  - `es depends_on es-setup` is `service_healthy`;
  - `es-setup` has no `restart`;
  - the merged `kibana` `ELASTICSEARCH_HOSTS` is `https://es:9200` (P2 ordering).
- [ ] **Step 2: Run** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Compose`. Expected: FAIL.
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Live check.** In a scratch folder, `docker compose up -d --wait es kibana` in HTTPS mode. Expected:
  - `docker compose cp es-setup:/usr/share/elasticsearch/config/certs/ca/ca.crt $TMPDIR/ca.crt` works (**V14**), before and after `es-setup` exits;
  - `curl --cacert $TMPDIR/ca.crt -u elastic:<pw> https://localhost:9200` → 200;
  - `ca.fingerprint` equals `openssl x509 -fingerprint -sha256 -noout -in $TMPDIR/ca.crt`, colons removed and lowercased;
  - Kibana is healthy.
- [ ] **Step 6: Commit:** `git add docker-compose*.yml tests/ && git commit -m "Add HTTPS overlays for Elasticsearch and Kibana"`

### Task 14: Platform and storefront over TLS, dev-cert delivery, CA fingerprint

**Reads:** SPEC §6 (rows `platform.https`, `frontend.https`), §8.1 (*build* step 3; *start* step 9), §10; DEC E4, E5, E8, E10, E11, E12; FC §10, §11, §14; FU *Amendments* (fingerprint format).

**Files:**
- Create: `docker-compose.platform.https.yml`, `docker-compose.frontend.https.yml`, `frontend/nginx/https/default.conf.template`, `scripts/https-certs.ps1`, `tests/unit/HttpsCerts.Tests.ps1`, `tests/compose/Entrypoint.Tests.ps1`
- Modify: `backend/entrypoint.sh`, `frontend/Dockerfile`, `build.ps1`, `start.ps1`, `scripts/_init.ps1`

**Interfaces — Produces:**
```powershell
Export-DevCertificate [-Destination] <string> -> [bool]   # dotnet dev-certs https --export-path <dir>/localhost.pem --format PEM --no-password
Copy-DevCertificateToVolume [-VolumeName] <string> [-SourceDir] <string> -> [void]   # docker container create -v <vol>:/certs alpine; docker cp <dir>/. <c>:/certs/dev/; docker rm
Sync-DevCertificate [-SolutionFolder] <string> [-VolumeName] <string> -> [void]   # Export-DevCertificate into backend/certs/ when localhost.pem is missing, then Copy-DevCertificateToVolume
Test-DevCertificateTrusted -> [bool]                      # dotnet dev-certs https --check --trust
Get-TrustInstructions -> [string]
```

Content:
- **`platform.https`:**
  - `ASPNETCORE_URLS=https://+:8080`, `VirtoCommerce__AllowInsecureHttp=false`, and `https` public URLs;
  - `Kestrel__Certificates__Default__Path=/certs/dev/localhost.pem` and `…KeyPath=/certs/dev/localhost.key`;
  - the `certs` volume `:ro` at `/certs`;
  - healthcheck `curl -fsk https://localhost:8080/health`.
- **`frontend.https`:** `NGINX_ENVSUBST_TEMPLATE_DIR=/etc/nginx/templates-https`, `PLATFORM_SCHEME=https`, and the `certs` volume `:ro` at `/certs`.
- **https template:** `listen 8080 ssl;`, `ssl_certificate /certs/dev/localhost.pem;`, `ssl_certificate_key /certs/dev/localhost.key;`, and the same include as the http template. Proxying to the platform doesn't verify the internal hop.
- **`entrypoint.sh`:** if `/certs/ca/ca.fingerprint` exists and `SEARCH_PROVIDER` is set, `export "Search__${SEARCH_PROVIDER}__CertificateFingerprint=$(tr -d '[:space:]' < /certs/ca/ca.fingerprint)"`. Then `exec "$@"`.

- [ ] **Step 1: Write the failing tests:**
  - `HttpsCerts.Tests.ps1` (tag `Unit`):
    - `trust instructions name both routes`: the text contains `dotnet dev-certs https --trust`, `SSL_CERT_DIR`, `/usr/local/share/ca-certificates` and `update-ca-certificates`.
    - `Sync-DevCertificate exports only when the export is missing`, with `Mock Export-DevCertificate` and `Mock Copy-DevCertificateToVolume`:
      - no `backend/certs/localhost.pem`: export is called once;
      - the file is present: export is called 0 times;
      - the copy is called once in both cases.

      This covers a folder built in HTTP mode and later switched to HTTPS.
  - `Entrypoint.Tests.ps1` (tag `Compose`; needs a daemon). Pipe `backend/entrypoint.sh` through stdin: `docker run --rm -i -e SEARCH_PROVIDER=ElasticSearch8 alpine sh -c 'mkdir -p /certs/ca && echo ab12 > /certs/ca/ca.fingerprint && cat > /e.sh && sh /e.sh env'`.
    - The output contains `Search__ElasticSearch8__CertificateFingerprint=ab12`.
    - Without the file, no such line appears.
  - The matrix and the drift test gain the HTTPS platform and storefront cases.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier All`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **build** step 3: in HTTPS mode, call `Export-DevCertificate` into `backend/certs/`. Add that folder to `.gitignore`.
  - **start:**
    - in HTTPS mode, call `Sync-DevCertificate` before `up`;
    - at step 9, print `Get-TrustInstructions` when `Test-DevCertificateTrusted` is `$false`, and print the setup CA's path with the same instructions.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Live check.** Run a full HTTPS stack in a scratch folder: `./build.ps1 -nonInteractive`. Expected:
  - `curl -fsk https://localhost:8090/health` → 200;
  - **V8:** `docker compose exec vc-frontend sh -c 'cat /etc/nginx/conf.d/default.conf; nginx -t'`. It has no `${`, it has `proxy_pass https://vc-platform-web:8080;`, `$uri` is intact, and the test is OK.
- [ ] **Step 6: E11 (SPEC §15 #2).**
  1. Rebuild the search index: `POST https://localhost:8090/api/search/indexes/index` with a token and the body `[{"documentType":"Product","deleteExistingIndex":true}]`.
  2. Check `curl --cacert ca.crt -u elastic:<pw> https://localhost:9200/_cat/indices`. Expected: the product index exists, and `docker compose logs vc-platform-web` has no `RemoteCertificate` error.
  3. Negative control: write `00` into `ca.fingerprint` in the volume and restart the platform. The log then shows a certificate error.

  **Stop and report** if the positive case fails.
- [ ] **Step 7: Switch modes on the same volumes.** This is the upgrade path: a migrated folder starts in HTTP mode.
  1. In a new scratch folder, run `./build.ps1 -nonInteractive -allowInsecureHttp` (sample data on). Record `totalCount` from `POST /api/stores/search` with `{}` and the product index document count (`_cat/indices`).
  2. Run three switches in turn: `./start.ps1 -allowInsecureHttp:$false`, then `./start.ps1 -allowInsecureHttp`, then `./start.ps1 -allowInsecureHttp:$false`.

  Expected after each switch:
  - `COMPOSE_FILE` has `.https.yml` entries iff the mode is HTTPS, and `FRONTEND_PORT` is `443` in HTTPS mode and `80` in HTTP mode (P17);
  - the first switch to HTTPS exports the dev certificate (`backend/certs/localhost.pem` appears);
  - in HTTPS mode, `curl --cacert ca.crt -u elastic:<ELASTIC_PASSWORD> https://localhost:9200` → 200, and Kibana signs in as `kibana_system`;
  - a token is issued with `ADMIN_PASSWORD`, and the store `totalCount` and the product document count equal the recorded values.

  **Stop and report** if Elasticsearch rejects `ELASTIC_PASSWORD` on the first secured start, or if data is lost.
- [ ] **Step 8: Commit:** `git add docker-compose*.yml frontend/ backend/ scripts/ build.ps1 start.ps1 .gitignore tests/ && git commit -m "Serve platform and storefront over HTTPS"`

## Phase D — Source mode

### Task 15: Source modules with the Docker platform

**Reads:** SPEC §7.1, §7.3, §11 (*file sharing*, *form*); DEC H2, E10; FC §13, §14; FU *Amendments* (`-DiscoveryPath`); this plan P16.

**Files:**
- Create: `scripts/source-mode.ps1`, `tests/unit/SourceMode.Tests.ps1`
- Modify: `scripts/preflight.ps1`, `start.ps1`, `build.ps1`, `scripts/_init.ps1`, `tests/compose/ComposeConfig.Tests.ps1`

**Interfaces — Produces:**
```powershell
Split-ModuleSourcePaths [-Value] <string> -> [string[]]
Get-ModuleSourceKind [-Paths] <string[]> -> [pscustomobject]       # @{ Kind='none'|'webfolders'|'modulesfolder'|'mixed'|'invalid'; Entries }
Get-ModuleIdFromManifestText [-Text] <string> -> [string]
Get-ModuleMountPlan [-Classification] <psobject> -> [pscustomobject[]]   # @{ Source; Target }; Target under /opt/virtocommerce/platform/modules
New-ModulesComposeYaml [-MountPlan] <pscustomobject[]> -> [string]
Write-ModulesComposeFile [-SolutionFolder] <string> [-MountPlan] <pscustomobject[]> -> [void]   # deletes the file when the plan is empty
Test-FileSharing [-Path] <string> -> [bool]                         # docker run --rm -v <path>:/x:ro alpine true; $false on 'mounts denied'
```

- [ ] **Step 1: Write the failing tests:**
  - `SourceMode.Tests.ps1` (tag `Unit`), with fake trees in `TestDrive:`. Classification:
    - two `*.Web` folders, each with `module.manifest` → `webfolders`;
    - one folder without a manifest, empty or not → `modulesfolder`;
    - one of each → `mixed`;
    - a missing path → `invalid`;
    - an empty value → `none`.
  - The module id is read from `<module><id>VirtoCommerce.Catalog</id></module>`.
  - Mount plans:
    - `webfolders` → `/opt/virtocommerce/platform/modules/VirtoCommerce.Catalog`;
    - `modulesfolder` → `/opt/virtocommerce/platform/modules`.
  - `Invoke-Preflight reports mixed form`: the errors contain `MODULE_SOURCE_PATHS`.
  - `Invoke-Preflight reports mounts denied`: `Mock Test-FileSharing { $false }`, and the errors contain `File sharing`.
  - Matrix (tag `Compose`): with a generated `platform-modules.yml`, the platform volume at `/opt/virtocommerce/platform/modules` is the bind source, not `modules-data`, because volumes merge by target.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier All`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **start:** before normalizing, call `Write-ModulesComposeFile` when the platform runs in Docker, and pass `-HasSourceModules`.
  - **build:** with a `modulesfolder`, pass that folder as `-DiscoveryPath` to `vc-build` (§7.3).
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add scripts/ start.ps1 build.ps1 tests/ && git commit -m "Mount module sources into the Docker platform"`

### Task 16: Platform from source

**Reads:** SPEC §7.1, §7.2 (whole), §8.1 (*start* steps 4, 6; *stop*), §11 (symlinks, build output, user secrets); DEC H3, H4, H5, H6, B6, H7; FU §1; FC §12, §13; this plan P8, P9, Review Focus 5.

**Files:**
- Modify: `scripts/source-mode.ps1`, `scripts/settings-file.ps1`, `scripts/preflight.ps1`, `start.ps1`, `stop.ps1`
- Modify: `tests/unit/SourceMode.Tests.ps1`, `tests/unit/SettingsFile.Tests.ps1`, `tests/unit/Preflight.Tests.ps1`

**Interfaces — Produces:**
```powershell
Get-PlatformSourceKind [-Path] <string> -> [string]            # 'checkout' (src/VirtoCommerce.Platform.Web/VirtoCommerce.Platform.Web.csproj) | 'prebuilt' (VirtoCommerce.Platform.Web.dll) | $null
Get-PlatformContentRoot [-Path] <string> [-Kind] <string> -> [string]
Test-PlatformBuildOutput [-Path] <string> [-Kind] <string> -> [bool]   # checkout: src/VirtoCommerce.Platform.Web/bin/**/VirtoCommerce.Platform.Web.dll
Get-SourcePlatformCommand [-Path] <string> [-Kind] <string> -> [pscustomobject]   # @{ FilePath='dotnet'; Arguments; WorkingDirectory=<content root> }
Get-ModuleLinkPlan [-Classification] <psobject> [-ContentRoot] <string> -> [pscustomobject[]]   # @{ LinkPath; Target }
Set-ModuleLinks [-LinkPlan] <pscustomobject[]> -> [string]     # $null on success, else an error naming the real non-empty modules dir
Add-GitInfoExclude [-CheckoutPath] <string> [-Entry] <string> -> [bool]   # $true if it added the entry
Write-PlatformSettingsFile [-Path] <string> [-Flat] <IDictionary> -> [void]
Get-ShadowedKeys [-SecretsJson] <string> [-SettingKeys] <string[]> -> [string[]]
Test-SymlinkRights -> [bool]
Start-SourcePlatform [-Command] <psobject> [-LogDir] <string> -> [int]   # pid; ASPNETCORE_ENVIRONMENT=Development; writes logs/platform.log and logs/platform.pid = "<pid>;<StartTime.ToUniversalTime().Ticks>"
Stop-SourcePlatform [-LogDir] <string> -> [bool]                         # kills the process TREE ((Get-Process -Id $pid).Kill($true)) only when pid and start time both match; always removes the pid file
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`, using `TestDrive:` trees):
  - `source kind detection`: checkout, prebuilt and empty (`$null`).
  - `command lines`:
    - checkout → `run --no-build --project <content root>`, in `<path>/src/VirtoCommerce.Platform.Web`;
    - prebuilt → `VirtoCommerce.Platform.Web.dll`, in `<path>`.
  - `link plans`:
    - `webfolders` → `<root>/modules/<id>`;
    - `modulesfolder` → `<root>/modules`.
  - `Set-ModuleLinks refuses a real non-empty modules dir`: the error names that path. On Linux and macOS the link test creates real symlinks.
  - `Add-GitInfoExclude is idempotent`: the first call returns `$true`, the second `$false`, and the entry appears once.
  - `Get-ShadowedKeys`: `{"ConnectionStrings:VirtoCommerce":"x"}` ∩ settings keys → that key.
  - `Stop-SourcePlatform`:
    - with a pid of a process that no longer exists, it returns `$false` and removes the file;
    - with a live pid whose recorded start time differs (PID reuse), it doesn't kill the process;
    - with a matching `pwsh` parent that started a sleeping child `pwsh`, both are gone afterwards. This is the `dotnet run` launcher-and-child case.
  - `preflight`:
    - when not skipped, a missing build output is an error naming the folder;
    - when `SKIP_PLATFORM=true`, there is no build-output error.
- [ ] **Step 2: Run** `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit`. Expected: FAIL.
- [ ] **Step 3: Implement `start.ps1`** steps 4 and 6.
  - **Settings file:**
    1. `Write-PlatformSettingsFile` with `Get-PlatformSettings -Topology Host`.
    2. For a checkout, call `Add-GitInfoExclude 'VirtoCommerce.Platform.Web.settings.json'`.
    3. Place the module links.
    4. In HTTPS mode, run `docker compose up -d --wait es-setup`, then `docker compose cp es-setup:/usr/share/elasticsearch/config/certs/ca/ca.fingerprint`, and pass the value as `-CaFingerprint`.
  - **Launch:** unless `SKIP_PLATFORM=true`, launch and wait; otherwise print the launch command.
  - **Preflight:** on Windows, when the link plan is non-empty and `Test-SymlinkRights` is `$false`, fail with "Enable Developer Mode or run an elevated shell".
  - **Warnings:** warn about shadowed keys from `~/.microsoft/usersecrets/VirtoCommerce.Platform.Web/secrets.json`, or on Windows `%APPDATA%\Microsoft\UserSecrets\…`.
  - **`stop.ps1`:** also calls `Stop-SourcePlatform`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Live check.**
  1. Make a prebuilt platform with `vc-build install --root $TMPDIR/pf …` (stable).
  2. Set `PLATFORM_SOURCE_PATH` to it. Remove `docker-compose.platform.yml` from `COMPOSE_FILE`.
  3. Run `./start.ps1 -nonInteractive`. Expected:
     - `curl -fs http://127.0.0.1:8090/health` → 200, after the 23-module check;
     - `logs/platform.pid` exists.
  4. `./stop.ps1`: the process is gone and the pid file is deleted.
  5. **V13:** with the storefront listed (`frontend-hostplatform`), `curl -fsk <Storefront URL from Get-ServiceUrls>/` returns the storefront and the proxied `/graphql` reaches the platform.

  On a native Linux engine (`docker info` doesn't say Docker Desktop), if V13 fails with the default `BIND_ADDRESS=127.0.0.1`, **stop and report** (H7 vs D9).
- [ ] **Step 6: Commit:** `git add scripts/ start.ps1 stop.ps1 tests/ && git commit -m "Run the platform from source"`

## Phase E — Installer and delivery

### Task 17: Payload installer

**Reads:** SPEC §4.3, §5.2, §8 (table); DEC A3, A5, B2–B5, C2; this plan P7, P12, Review Focus 4.

**Files:** Create `install.ps1` (payload role only) and `tests/unit/Install.Tests.ps1`; modify `scripts/payload.ps1`.

**Interfaces — Consumes:** Tasks 1, 4, 5 and 7. **Produces:**
```powershell
Copy-Payload [-Root] <string> [-Destination] <string> -> [void]   # now also overwrites each EXISTING old-named script with its guard; adds none
Invoke-PayloadInstall [-PayloadPath] <string> [-TargetFolder] <string> [-Bound] <IDictionary> [-NonInteractive] <bool> -> [int]   # exit code
Update-VcBuildTool -> [bool]                                      # dotnet tool update --global VirtoCommerce.GlobalTool
Invoke-SolutionBuild [-TargetFolder] <string> [-SkipSampleData] <bool> [-NonInteractive] <bool> -> [int]
# install.ps1 param: [string]$targetFolder='VirtoLocal', [string]$branch, [ValidateSet(...)][string]$dbProvider, [string]$releaseChannel,
#   [string]$customPackagesJson, [string]$customFrontendUrl, [switch]$allowInsecureHttp, <five skip switches under one comment>,
#   [bool]$skipSampleData=$false, [switch]$nonInteractive, [Obsolete("Use -releaseChannel")]$vcSolutionVersion,
#   [Obsolete("Set STACK_VERSION in .env")]$elasticsearchVersion, [Parameter(DontShow)][string]$payloadPath
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`). Use `Mock Update-VcBuildTool` and `Mock Invoke-SolutionBuild`.
  - **`fresh install`** (`-dbProvider postgres -releaseChannel stable -nonInteractive`):
    - `.env` exists, and the 4 secrets match `^[A-Za-z0-9]{16}$`;
    - `COMPOSE_FILE` equals the default postgres HTTPS list, and `START_LOCAL_LAYOUT=2`;
    - `Invoke-SolutionBuild` is called once with `-NonInteractive $true`.
  - **`re-run keeps secrets and user files`:** add `my.override.yml` to `COMPOSE_FILE`, then re-run. The secrets are byte-equal, and `my.override.yml` is last.
  - **`layout-1 folder`:** the fixture `.env` plus `start-VC-solution.ps1` are migrated, the guard overwrites that script (content equals the repo guard), and no `build-VC-solution.ps1` is added.
  - **`non-interactive with missing keys fails naming them`:** with no `-dbProvider` and no `-releaseChannel`, the exit code is 1 and the output contains `COMPOSE_FILE` and `RELEASE_CHANNEL`.
  - **`-allowInsecureHttp`:** no `.https.yml` entries, and `FRONTEND_PORT=80` (P17).
  - **`.env written by a wrapper beforehand`:** a pre-written `.env` with `COMPOSE_FILE` including `docker-compose.es-limited.yml` keeps it, and only the empty keys are filled (SPEC §8, *Optional files*).
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/Install.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement** `Invoke-PayloadInstall`, following SPEC §4.3 steps 1–8.
  - Step 7 uses `Read-YesNo` for "update vc-build" and "build now", both defaulting to yes.
  - `install.ps1` with `-payloadPath` dot-sources `$payloadPath/scripts/_init.ps1`, then calls it.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit:** `git add install.ps1 scripts/payload.ps1 tests/unit/Install.Tests.ps1 && git commit -m "Add the payload installer"`

### Task 18: Bootstrap, forwarder and README

**Reads:** SPEC §4.1, §4.2, §5; DEC A1, A2, A6, A7, A9, A10; FC §1, §2, §3; README.md (whole).

**Files:** Modify `install.ps1` (bootstrap role), `VirtoLocal_create_local_files.ps1` (the forwarder) and `README.md`; create `tests/unit/Bootstrap.Tests.ps1`.

**Interfaces — Produces** (defined in `install.ps1` above the line `if ($MyInvocation.InvocationName -eq '.') { return }`):
```powershell
Resolve-ReleaseRef [[-Branch] <string>] -> [pscustomobject]   # @{ Ref; IsTag }; empty Branch => GET api.github.com/repos/VirtoCommerce/start-local/releases/latest .tag_name
Get-PayloadZipUrl [-Ref] <string> [-IsTag] <bool> -> [string] # https://github.com/VirtoCommerce/start-local/archive/refs/{tags|heads}/<ref>.zip
Get-PayloadRoot [-ExtractDir] <string> -> [string]            # the single top-level folder; [InvalidOperationException] otherwise
Get-LegacyInstallerMessage [-Ref] <string> -> [string]        # A10 text with raw.githubusercontent.com/.../refs/heads/<ref>/VirtoLocal_create_local_files.ps1
```

- [ ] **Step 1: Write the failing tests** (tag `Unit`; dot-source `install.ps1`):
  - `explicit branch skips the API`: `Mock Invoke-RestMethod`, `-Times 0`, and `IsTag $false`.
  - `latest release`: `Mock Invoke-RestMethod { @{ tag_name='v2.0.0' } }` gives `Ref v2.0.0`, `IsTag $true`.
  - `zip URLs`:
    - `release/1.0` (heads) → `…/archive/refs/heads/release/1.0.zip`;
    - `v2.0.0` (tags) → `…/archive/refs/tags/v2.0.0.zip`.
  - `payload root`: one folder in `TestDrive:` is returned; two folders throw.
  - `legacy message` contains `release/1.0` and `VirtoLocal_create_local_files.ps1`.
- [ ] **Step 2: Run** `pwsh -NoProfile -c "Invoke-Pester -Path tests/unit/Bootstrap.Tests.ps1 -Output Detailed"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Bootstrap role:** resolve the ref → download the zip into a temp folder → `Expand-Archive` → `Get-PayloadRoot`.
    - Without `install.ps1` in the payload, throw `Get-LegacyInstallerMessage`.
    - Otherwise run `& "$root/install.ps1" @PSBoundParameters -payloadPath $root -branch $ref`.
    - Set `$ErrorActionPreference = 'Stop'`.
  - **Forwarder:** exactly the 4 lines in SPEC §4.1.
  - **README:**
    - the new one-liner (`releases/latest/download/install.ps1`) and the network allowlist from SPEC §4.2;
    - a `.env` reference, plus the parameter table from SPEC §8;
    - HTTPS and trust (both routes), and the source modes;
    - an *Upgrading from 1.x* section: migration, HTTP mode, `BIND_ADDRESS`, Redis, the guards, `release/1.0`;
    - remove and `-keepData`.
- [ ] **Step 4: Run** the same command, then `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier All`. Expected: PASS.
- [ ] **Step 5: Live check.** `pwsh -NoProfile -File install.ps1 -branch feat/non-interactive -targetFolder $TMPDIR/sl-boot -nonInteractive -dbProvider postgres -releaseChannel stable -allowInsecureHttp`, after the branch is pushed (otherwise skip and note it). Expected: the folder is filled and the build starts.
- [ ] **Step 6: Commit:** `git add install.ps1 VirtoLocal_create_local_files.ps1 README.md tests/unit/Bootstrap.Tests.ps1 && git commit -m "Add release-pinned bootstrap and forward the old one-liner"`

## Phase F — CI

### Task 19: CI workflow for the unit and compose tiers

**Reads:** SPEC §12 (tiers table); DEC G1; FU §5 and *Amendments*; CIR §6 and *Recommendations* item 2; `.github/workflows/runner-probe.yml` (macOS Compose setup).

**Files:** Create `.github/workflows/ci.yml`.

Jobs:
- **`unit`**, on `[ubuntu-24.04, windows-2025, macos-15]`: `pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Tier Unit`.
- **`compose`**, on the same 3 OSes: `-Tier Compose`. macOS installs `docker docker-compose` with Homebrew and the `cliPluginsExtraDirs` line from `runner-probe.yml`. Daemon-only tests skip themselves.
- **`compose-min`**, on Ubuntu: download Compose v2.18.0, as in Task 7 step 6, set `SL_COMPOSE_BINARY`, and run `-Tier Compose`.
- **Workflow level:** `concurrency: { group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: true }`, and a job-level `if:` that skips docs-only changes (CIR §6).

- [ ] **Step 1: Write the workflow.** It is the test runner itself; there is no separate test.
- [ ] **Step 2: Run** each job's command locally. Expected: PASS. Also parse the file: `pwsh -c "Get-Content .github/workflows/ci.yml -Raw | Out-Null"`, plus `uvx --from yamllint yamllint -d relaxed .github/workflows/ci.yml`, which exits 0.
- [ ] **Step 3: Commit:** `git add .github/workflows/ci.yml && git commit -m "Add CI for unit and compose tiers"`. The run on GitHub is F4.

### Task 20: Smoke workflow

**Reads:** SPEC §12 (*Smoke*, *Runners*); DEC G1; FU *Amendments* (runner probe); CIR *Recommendations* items 1 and 3; this plan F1.

**Files:**
- Create: `.github/workflows/smoke.yml`, `tests/smoke/Invoke-Smoke.ps1`, `tests/smoke/Invoke-MigrationSmoke.ps1`
- Delete: `.github/workflows/runner-probe.yml`

`Invoke-Smoke.ps1 -TargetFolder <dir>`:
1. Pre-write `.env` with `COMPOSE_FILE` = the default postgres HTTPS list without Kibana, plus `docker-compose.es-limited.yml`.
2. Run `install.ps1 -payloadPath $repo -targetFolder <dir> -nonInteractive -releaseChannel stable -skipSampleData $true`.
3. Assert, all with `-SkipCertificateCheck`:
   - `https://localhost:8090/health` → 200;
   - a token is issued with `.env`'s `ADMIN_PASSWORD`;
   - `GET /api/platform/modules` lists at least 23 installed modules.

`Invoke-MigrationSmoke.ps1`:
1. Download `release/1.0`'s `VirtoLocal_create_local_files.ps1` and run it non-interactively: `-dbProvider postgres`, then build and start with `latest-stable`.
2. Run `install.ps1 -payloadPath $repo` over the folder.
3. Assert:
   - the `virto_*` volumes are kept;
   - `vc-platform:<project>-latest` exists (retagged);
   - the platform is healthy on `http://localhost:8090`;
   - a sign-in with `admin`/`store` fails, because C1 applied `ADMIN_PASSWORD`, and a sign-in with `ADMIN_PASSWORD` works.

Lanes:

| Lane | Setup | Timeout |
|------|-------|---------|
| `ubuntu-24.04` | native Docker | – |
| `windows-2025` | WSL2 Docker, the probe's install step, `dockerd -H tcp://0.0.0.0:2375` inside WSL, `DOCKER_HOST=tcp://localhost:2375` in Windows `pwsh` | `timeout-minutes: 40`, for runner-images#14938 |
| `macos-15-intel` | colima `--cpu 3 --memory 6` | – |
| `migration` | Ubuntu | – |

On every lane: an `actions/cache` for `~/.nuget/packages` and the vc-build download folder, keyed on the OS and the hash of `bundles/stable.json`. Start `docker compose pull --quiet --ignore-buildable` in the background before the build (CIR items 1 and 3).

The Windows lane verifies SPEC §15 #5 first: `docker version --format '{{.Server.Os}}'` must print `linux`, or the lane fails with that message.

- [ ] **Step 1: Write the two scripts and the workflow.**
- [ ] **Step 2: Run** `pwsh -NoProfile -File tests/smoke/Invoke-Smoke.ps1 -TargetFolder $TMPDIR/sl-smoke` locally. Expected: PASS. Then run `Invoke-MigrationSmoke.ps1`, which needs F1. Expected: PASS. Without F1, record that it was skipped.
- [ ] **Step 3: Commit:** `git add .github/workflows/smoke.yml tests/smoke/ && git rm .github/workflows/runner-probe.yml && git commit -m "Add smoke workflow and retire runner probe"`. The runs on GitHub are F4.
