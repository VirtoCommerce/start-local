# start-local redesign: choice prompts and spec review

Status: **review, point-in-time.** The prompt record (§3) is a verbatim, append-only record of the multiple-choice prompts the user answered while the redesign was designed. The review (§2) compares those answers against the [decision log](2026-10-15-redesign-decisions.md) and the [spec](2026-10-15-env-first-redesign-design.md) as they stood on 2026-10-15. Apply accepted findings to those two documents; record outcomes here in an *Outcome* section, original intact.

## 1. Sources

- 15 UI prompts (52 questions), asked 2026-10-14 23:12 UTC to 2026-10-15 01:28 UTC in Claude Code session `ed9f4ea1-672b-46c5-a4f1-188c91b03fa9`.
- 1 question answered in chat, 2026-10-15 01:34 UTC (§3.16).
- Code facts checked against `dev` at `6a43ade` (`VirtoLocal_create_local_files.ps1`, `build-VC-solution.ps1`, `docker-compose*.yml`).

Status legend used in §3:

| Mark | Meaning |
|------|---------|
| ✅ | Recorded as answered |
| ↪ | Superseded by a later prompt |
| ⚠️ | The spec diverges from the answer, and says so (*pending confirmation*) |
| ❌ | The spec diverges from the answer, or rests on a false premise, without saying so |
| ➕ | The spec goes beyond the answer: an added choice that was never asked |
| ℹ️ | The fact check refuted the user's premise; the decision still follows the user's intent |

## 2. Review

52 prompt questions, by primary mark: 43 ✅, 4 ↪, 3 ❌, 1 ⚠️, 1 ➕. Seven ✅ answers carry a second mark: 3 ⚠️, 1 ➕, 3 ℹ️. Every answer has a home in the decision log. The findings below are ranked by impact.

### 2.1 Contradictions

1. **Old installers don't fail cleanly with 404 (A5, P3).** The premise behind the chosen option (*"old copies without -branch fail with raw 404 errors"*) is false for the planned layout:
   - The spec keeps most file names the old installer fetches by name: `build-`, `start-`, `stop-`, `remove-VC-solution.ps1`, `docker-compose.yml` and the three provider files (spec §5, §6).
   - `dev:VirtoLocal_create_local_files.ps1` doesn't set `$ErrorActionPreference = 'Stop'`, so a failed `Invoke-WebRequest` doesn't stop the script (verified live with `pwsh`, 2026-10-15: a 404 prints an error and the next statement runs).
   - A saved old installer run without `-branch` therefore: writes a layout-1 `.env` (`DB_PROVIDER`, fresh passwords), downloads the new files that kept their names, skips the new ones (`.env.example`, the feature compose files, `scripts/migrate.ps1`), and runs the new `build-VC-solution.ps1` with `-vcSolutionVersion` / `-custom*` / `-skipSampleData`.
   - The result is a mixed-layout folder, not a 404 stop. The user rejected a stub (P3), so one of these must be chosen: rename a file the old installer fetches before build (it then really 404s, but continues), make the new scripts refuse a layout-1 folder that has no `START_LOCAL_LAYOUT`, or accept the mixed folder and document it.
2. **Several stacks share one platform image (D3, P10).** P10 asked only about volumes. The compatibility surface (item 2) and the spec (§6) keep the image tags `vc-platform:local-latest` and `vc-frontend:local-latest`. Two folders that build different solutions overwrite each other's image, so restarting stack A runs stack B's platform. New folders need per-project tags, for example derived from `VOLUME_PREFIX`; migrated folders can keep `local-latest`.
3. **Non-interactive runs change the admin password of migrated folders (C1, P5).** Spec §8 generates a password whenever `ADMIN_PASSWORD` is empty in a non-interactive run of start. Migration fills missing keys with `.env.example` defaults, and that default is empty. So the first unattended start of a migrated folder (CI, a cloud routine, or redirected stdin via B4's auto-detect) replaces `admin` / `store`. That breaks the compatibility surface (item 3). Also open:
   - Saving the generated password into `.env` is marked *assumed* in C1, but spec §8 states it as decided, and spec §15 doesn't list it.
   - Spec §8.1 (start, step 8) applies the admin password on every start, so a password changed in the admin UI reverts on the next start.

### 2.2 Divergences not marked as pending

4. **H5 goes beyond the P8 answer.** The answer was conditional: user-secrets, and environment variables *only if* a start-launched platform doesn't load them. The fact check (§12) showed both launch forms do load them, yet H5 still passes environment variables, because the user-secrets store is shared across stacks (D3). The launch also forces `ASPNETCORE_ENVIRONMENT=Development`. Neither is in spec §15.
5. **Link files and `.generated/` weaken the P7 answer.** The answer was *"COMPOSE_FILE + script arg that rewrites it. Manual switch = switching config file"*, chosen because plain `docker compose` works in the folder. With link files, removing `docker-compose.elasticsearch.yml` from `COMPOSE_FILE` by hand leaves `docker-compose.platform-elasticsearch.yml` listed, and raw `docker compose` fails on an undefined `depends_on` until a script runs. A hand-edited `.env` likewise needs a start run to reach `.generated/`. Spec §15 lists both as design choices, but not that they qualify P7's "manual switch" promise.
6. **E6 (TLS in each service, no reverse proxy) was never asked** and isn't marked pending.

### 2.3 Flagged divergences (sign-off needed, no defect)

- **D8** reverses the P11 answer *"Follow STACK_VERSION"*: the provider follows the installed module instead, because no bundle ships `VirtoCommerce.ElasticSearch9`.
- **E10, E11, E12**, v2.0.0, bootstrap delegation, `-skipPlatform` with a source platform: listed in spec §15.

### 2.4 Refuted premises (decision kept)

- **E7 (P12):** *"frontend has it's own in repo I think"*. vc-frontend ships no certificate, so the storefront reuses the dev-certs export (E8, P14).
- **E3, E9 (P14):** *"it was official at least for ES 8"*. Elastic's official compose serves Kibana over plain HTTP in 8.0–8.19. Kibana's own HTTPS comes from the reference repo; the decision (ES setup CA) is the one the user chose.
- **D2 (P11):** heap auto-sizing verified (`-m 1g` gives `-Xmx512m`), so the keys are dropped, as the answer instructed.

### 2.5 Smaller defects

- **F2 lists steps that no longer exist.** *Resetting the Elasticsearch index* and *copying volumes to per-project names* don't happen: D7 keeps 8.18 and D3 keeps the `virto` prefix. Spec §9 lists only the Redis drop.
- **Compatibility surface, item 4** cites D3 for the Compose version; it is D4.
- **H2 / spec §7.3 leave the whole-`modules`-folder case undefined** (P8: *"symlink individual \*.web or whole modules folder"*). Neither says whether such an entry replaces the platform's `modules` folder or is nested inside it. *"Mounted whole"* has no mount point; mounting it at `/opt/virtocommerce/platform/modules` would hide the modules vc-build installed.

### 2.6 Outside the prompts

- `.env.example` sets `FRONTEND_PORT=443` (today `80`). Publishing a port below 1024 fails under rootless Docker.

### 2.7 Outcome (2026-10-15)

The user's verdicts on §2, applied to the decision log and the spec the same day:

| Finding | Outcome |
|---------|---------|
| 1. Old installers (A5) | The user reversed the P3 answer *"release/1.0, no stub"*. `dev` keeps `build-VC-solution.ps1` as a guard that throws an explanation (`-branch release/1.0`, the new installer, migration). The scripts get short verbs (`install.ps1`, `build.ps1`, `start.ps1`, `stop.ps1`, `remove.ps1`; new A8); `docker-compose*.yml` and `scripts/` keep their names. |
| 2. Shared image tags (D3) | Per-project tags `vc-platform:${COMPOSE_PROJECT_NAME}-latest` / `vc-frontend:…`; migration retags `local-latest`. |
| 3. Admin password (C1) | Not a defect: interactive runs keep `admin` / `store` with the change-password prompt, and non-interactive runs rewrite it, migrated folders included; running non-interactively is the user's choice. Saving the generated password stays assumed. |
| 4. H5 | Environment variables dropped: user secrets are the only channel. One source-run platform at a time. |
| 5. Link files and `.generated/` | `.generated/` dropped for `.env` interpolation (new C4). Link files stay pending. |
| 6. E6 | Confirmed: no reverse proxy. |
| D8 | Decided: a separate `SEARCH_PROVIDER` key, default `ElasticSearch8` (the user's third option, not the drafted one). |
| §2.5 F2, compatibility item 4 | Fixed. |
| §2.5 H2 | A `modules` folder entry becomes the platform's modules folder (the user's own `modules -> ../modules` setup); vc-build installs into it, so binaries and sources mix. |
| §2.6 `FRONTEND_PORT=443` | Withdrawn: today's default `80` is privileged too, so `443` adds no requirement. Port 443 publishes on Docker Desktop for Linux (live); rootless Docker needs `CAP_NET_BIND_SERVICE` on `rootlesskit` or `net.ipv4.ip_unprivileged_port_start=0` for either port (Docker docs). |
| §2.3 E10, E11, E12 | E10 confirmed (named volume for the dev-cert export; File Sharing only for module source paths). E11 reworked: the setup container writes `ca/ca.fingerprint` and the platform entrypoint reads it, so no `.env` key. E12 confirmed. |
| §2.3 v2.0.0, bootstrap delegation | Already confirmed by the user earlier; dropped from the pending list. |
| §2.3 `-skipPlatform` | Dropped: the platform runs in Docker or from the user's source path, never skipped. |
| §2.2 link files | Kept (new C5), after the `required: false` limitation was re-verified. |

## 3. Prompt record

Options are quoted as shown, *(R)* marking the option offered as recommended. Answers are quoted verbatim, typos included.

### 3.1 P1, 2026-10-14 23:12 UTC

**Release:** How should a release be marked, given dev stays the development branch?
- release/* + tag *(R)*: release/X.Y branches for hotfixes, plus a vX.Y.Z tag per release: an immutable zip and GitHub's 'latest release' API for the bootstrap
- release/* branches only: No tags. The bootstrap must list branches through the GitHub API (60 req/h unauthenticated, paginated) and sort them by semver
- Tags only: Releases cut from dev as tags; hotfixes are a new tag on a dev commit

Answer: "release/* + tag (Recommended)". → A1 ✅

**Payload:** How should the installer fetch the scripts and compose files for a release?
- One zip of the ref *(R)*: github.com/VirtoCommerce/start-local/archive/<ref>.zip: one request, a consistent file set, no file list inside the installer
- Manifest of files: Per-file downloads as today, but the list lives in a manifest file in the repo, not in the installer
- git clone, else zip: Clone when git is installed (updates = git pull, like Homebrew/oh-my-zsh); fall back to the zip otherwise

Answer: "One zip of the ref (Recommended)". → A2 ✅

**Update:** How does an existing VirtoLocal folder get updated to a newer release?
- Re-run create *(R)*: Running the installer on an existing folder updates the scripts in place, keeps .env and runs migration
- Separate update script: A new update-VC-solution.ps1 inside the folder pulls the latest release and migrates
- Not supported: Recreate the folder; only the data volumes survive

Answer: "Re-run create (Recommended)". → A3 ✅

**Old copies:** Old saved copies of the create script keep fetching files from dev by name. What should happen when dev has changed underneath them?
- Detect and stop *(R)*: dev's build/start scripts notice the caller is an old installer (no layout stamp) and stop with 're-download the installer'
- Accept breakage: No special handling; whatever dev has at the time runs
- Keep shims on dev: dev keeps the old file names and old parameters working: the frozen contract you'd rather avoid

Answer: "dev basically freezes". → ↪ P2, P3

### 3.2 P2, 2026-10-14 23:17 UTC

**Dev branch:** If dev freezes at its current state (serving old installer copies), where does new development happen?
- New main branch *(R)*: Create main from dev, make it the default branch and develop there; dev stays frozen for old installer copies
- release/* only: No integration branch: each release/X.Y branch is cut and developed directly
- dev, frozen per file: Keep developing on dev, but never change the files/params old installers fetch: the frozen-contract idea

Answer: "What can we do, that downloaded script running again keeps working, but new one downloadede from dev use new layout/files/logic, etc.? Ask user to use -branch parameter and point it to releases/1.0 created from current dev? frozen contract is out of scope, I don't want to keep legacy args and file names". → A4 ✅, refined by P3

**One-liner:** The README one-liner currently downloads the installer from dev. What should it download after the redesign?
- Latest release asset *(R)*: github.com/VirtoCommerce/start-local/releases/latest/download/VirtoLocal_create_local_files.ps1: always the newest released bootstrap, never in-progress code
- New branch's file: raw.githubusercontent.com/.../main/VirtoLocal_create_local_files.ps1: the bootstrap is small and stable, so main is fine
- Keep dev URL: Only dev's create script is replaced with the new bootstrap; everything else on dev stays frozen

Answer: "Latest release asset (Recommended)". → A6 ✅

**Latest:** How does the bootstrap decide which release to install when no ref is given?
- Releases 'latest' API *(R)*: GET /repos/VirtoCommerce/start-local/releases/latest → tag; one unauthenticated call (60 req/h limit)
- Version baked in: Like nvm: the bootstrap attached to each release carries its own tag, so the one-liner's file and payload always match; no API call
- Both: Baked-in tag by default; '-branch latest' (or similar) asks the API for the newest

Answer: "Releases 'latest' API (Recommended)". → A7 ✅

### 3.3 P3, 2026-10-14 23:26 UTC

**Old copies:** How should old saved installer copies keep working once the new layout lands?
- release/1.0 + one stub: Keep developing on dev; cut release/1.0 from current dev. dev keeps a single 3-line build-VC-solution.ps1 stub that prints 're-download the installer, or rerun with -branch release/1.0' and exits 1. No legacy args or logic
- release/1.0, no stub: Same, but nothing at the old paths: old copies without -branch fail with raw 404 errors; the README and release notes explain -branch release/1.0
- Dev on main, dev frozen: Move development and the default branch to main; dev is never touched again, so old copies keep working with zero user action. Costs a default-branch change against VirtoCommerce-org conventions

Answer: "release/1.0, no stub". → A4, A5 ❌ (§2.1, finding 1: the "404" premise doesn't hold)

### 3.4 P4, 2026-10-14 23:31 UTC

**Old params:** Old behavior now lives on release/1.0. Should the new layout on dev still accept the old parameters (-dbProvider, -elasticsearchVersion, -vcSolutionVersion, -customPackagesJson, -customFrontendUrl, -skipSampleData)?
- Obsolete shims, 1 release: Accepted with a warning and saved into .env; removed in the next minor release. Scripts/CI calling them keep working through one upgrade
- Drop them: Clean break on dev; release notes map each old param to its .env key. Anyone needing them uses -branch release/1.0
- Keep some as first-class: Keep the handy ones (e.g. -dbProvider, -vcSolutionVersion) as real overrides of .env keys; drop the rest

Answer: "Obsolete shims + keep some as first-class. Let's discuss which ones, probably at the end". → B1, B5 ✅ (settled in P15)

**Template:** Which template file does the release ship?
- .env.example *(R)*: Copied to .env only when the folder has none; re-running the installer can never overwrite a user's .env
- Committed .env: Your original idea: .env with empty secrets in the repo. Zip extraction must skip it on existing folders, and the root .gitignore's .env line goes

Answer: ".env.example (Recommended)". → B2 ✅

**Empty keys:** When a required .env key is empty (DB provider, version, manifest for custom), what happens?
- Ask once, save *(R)*: Prompt, write the answer into .env; later runs don't ask again
- Ask, don't save: Prompt every run until the user edits .env
- Never ask, fail: Your repo's style: list the missing keys and exit; .env is the only input

Answer: "Ask once, save (Recommended)". → B3 ✅

**Unattended:** How is a non-interactive run detected?
- Flag + auto-detect *(R)*: -nonInteractive, or automatically when stdin is redirected or CI=true
- Flag only: -nonInteractive must be passed explicitly
- Auto-detect only: No flag at all: redirected stdin or CI=true

Answer: "Flag + auto-detect (Recommended)". → B4 ✅

### 3.5 P5, 2026-10-14 23:39 UTC

**Admin pass:** How is the platform admin password handled?
- Empty keeps 'store' *(R)*: ADMIN_PASSWORD empty in .env.example: admin/store as today. When set, start applies it through the API and clears the forced change on first sign-in
- Generate like secrets: Installer fills ADMIN_PASSWORD with a random value and applies it; prints it at the end. Breaks the README's admin/store
- Ask during install: Treated as a required key: prompt once (default 'store'), save to .env

Answer: "Interactive: keep store. Non-interactive: create random password". → C1 ❌ (§2.1, finding 3: hits migrated folders; saving is assumed)

**Steps:** Where do the step switches live: update vc-build, install sample data, start after build?
- .env keys *(R)*: UPDATE_VC_BUILD, INSTALL_SAMPLE_DATA, START_AFTER_BUILD: asked once like other empty keys, then remembered
- Per run only: Asked every interactive run (defaults in -nonInteractive); not saved
- Mixed: Sample data in .env (it's about the solution); vc-build update and auto-start asked per run

Answer: "Per run only". → C2 ✅

**Modules:** How are module source folders mounted into the platform (module development, cloud routines)?
- Caller's override file *(R)*: The module repo ships its own compose override (one volume line per module) and adds it to COMPOSE_FILE in .env; start-local generates nothing
- MODULE_SOURCE_PATHS key: A list in .env; start reads each module.manifest for the id and writes a generated override
- Both: The key for convenience, override files for anything beyond mounts

Answer: "Everything, including platform, modules and frontend must be able to run via docker or source code. User decides which ones. If platform or frontend run from source, they don't need docker. If platform runs from docker, but some module isn't - "modules" folder or "*.Web" folder of module get's binded". → section H intro, H1, H2 ✅ (frontend narrowed by P9)

**Compose files:** How does DB_PROVIDER map to compose files?
- COMPOSE_FILE in .env *(R)*: Installer/migration writes COMPOSE_FILE=docker-compose.yml:docker-compose.postgres.yml (+ user overrides); plain 'docker compose logs' works inside the folder
- Scripts compute -f: Scripts build -f from DB_PROVIDER plus an EXTRA_COMPOSE_FILES key; raw docker compose in the folder doesn't see the DB override
- User owns COMPOSE_FILE: No DB_PROVIDER key at all; the user edits COMPOSE_FILE directly (installer sets it once)

Answer: "Explain difference and how current solution works". → ↪ P6, P7

### 3.6 P6, 2026-10-14 23:52 UTC

**Compose files:** With that explained: how should DB_PROVIDER map to compose files?
- COMPOSE_FILE, synced *(R)*: DB_PROVIDER stays the human key; scripts rewrite COMPOSE_FILE from it (+ user overrides) every run, so raw docker compose works in the folder
- Scripts compute -f: Today's model + EXTRA_COMPOSE_FILES key; raw docker compose needs -f flags
- Only COMPOSE_FILE: No DB_PROVIDER key; COMPOSE_FILE is the single truth

Answer: "I don't see explanation". → ↪ P7

**Run mode:** How does the user choose Docker or source for each component in .env?
- Path key, empty = Docker *(R)*: PLATFORM_SOURCE_PATH=, FRONTEND_SOURCE_PATH=, MODULE_SOURCE_PATHS= (list of *.Web or a modules folder). Empty means Docker; a path means source. One key per component
- Mode + path keys: PLATFORM_MODE=docker|source plus PLATFORM_PATH=..., same for frontend and modules; a path can stay set while switching mode
- Compose profiles: COMPOSE_PROFILES lists what runs in Docker (platform, frontend, ...); paths for source components in separate keys

Answer: "Path key, empty = Docker (Recommended)". → H1 ✅ (`FRONTEND_SOURCE_PATH` dropped by P9)

**Launcher:** When the platform or frontend runs from source, who launches it?
- start launches it *(R)*: start-VC-solution.ps1 runs dotnet run / yarn dev as background processes with log files and the .env config; stop stops them. Cross-platform
- Separate launcher scripts: Your repo's style: one script per component, run in its own terminal; start only brings Docker up and prints what to run
- User launches: start brings up the Docker part and prints the exact commands and env for the source components

Answer: "start launches it (Recommended)". → H3 ✅ (platform only, per P9)

**Platform src:** What counts as 'platform from source'?
- Both forms *(R)*: A vc-platform checkout (dotnet run on the .Web project) or a prebuilt platform folder (dotnet VirtoCommerce.Platform.Web.dll), detected from what the path contains, like your repo's two launchers
- Source checkout only: Only a vc-platform git checkout; dotnet run
- Prebuilt folder only: Only a vc-build install output on the host; no platform compilation

Answer: "Both forms (Recommended)". → H4 ✅

### 3.7 P7, 2026-10-15 00:07 UTC

**Compose files:** How should DB_PROVIDER map to compose files? (Focus each option to see how it works.)
- COMPOSE_FILE, synced *(R)*: DB_PROVIDER stays the human key; scripts rewrite COMPOSE_FILE from it every run
- Scripts compute -f: Today's model plus an EXTRA_COMPOSE_FILES key
- Only COMPOSE_FILE: No DB_PROVIDER key; COMPOSE_FILE is the single truth

The previews shown with the options:

```text
COMPOSE_FILE, synced
  TODAY (for comparison)
    .env:   DB_PROVIDER=postgres
    start:  docker compose -f docker-compose.yml \
                           -f docker-compose.postgres.yml up -d
    stop:   passes all 3 provider files to 'down'
    catch:  'docker compose logs' typed by hand in
            VirtoLocal loads ONLY docker-compose.yml
            -> platform without DB settings; every
            manual command needs the -f flags again

  THIS OPTION
    .env:   DB_PROVIDER=postgres
            COMPOSE_FILE=docker-compose.yml:docker-compose.postgres.yml
    Compose reads COMPOSE_FILE from .env natively,
    so plain 'docker compose up/logs/ps' works.
    Scripts rewrite COMPOSE_FILE from DB_PROVIDER
    (+ run-mode files / user overrides) each run.

    + raw docker compose works in the folder
    + hybrid modes = different file list
    - two keys must agree (scripts resync them;
      a hand edit of DB_PROVIDER alone is fixed
      on the next script run, not by raw compose)

Scripts compute -f
  THIS OPTION (= today + extras)
    .env:   DB_PROVIDER=postgres
            EXTRA_COMPOSE_FILES=my-override.yml
    start:  docker compose -f docker-compose.yml
                           -f docker-compose.postgres.yml
                           -f my-override.yml up -d

    + one key per concern, no drift
    - plain 'docker compose logs' in the folder
      still sees only docker-compose.yml

Only COMPOSE_FILE
  THIS OPTION
    .env:   COMPOSE_FILE=docker-compose.yml:docker-compose.postgres.yml
    (no DB_PROVIDER key)
    Scripts infer the provider from the file list
    (for the port check, connection string for a
    source-run platform).

    + one source of truth, fully Compose-native
    - switching DB = editing a file list
    - less readable for newcomers
```

Answer: "COMPOSE_FILE + script arg that rewrites it. Manual switch = switching config file". → C3 ✅, B5 (`-dbProvider`) ✅; link files and `.generated/` ➕ (§2.2, finding 5)

### 3.8 P8, 2026-10-15 00:14 UTC

**Src config:** When the platform runs from source, how does it get its config (DB connection string, search, Redis), which lives in .env?
- Env vars at launch *(R)*: start passes ConnectionStrings__VirtoCommerce, Search__*, etc. as environment variables to dotnet; nothing written into the platform checkout
- dotnet user-secrets: Your repo's approach: start writes the settings into the platform's user-secrets store; also applies when the user runs the platform from an IDE
- appsettings.Development.json: start generates a Development settings file in the platform folder; IDE runs pick it up, but it's a file in someone's checkout

Answer: "dotnet user-secrets for case when user runs from source code. If we run (or we run from binaries compiled from that code) - check if it takes into account saved dotnet user-secrets, if not - use env vars". → H5 ➕ (§2.2, finding 4)

**Src modules:** A module runs from source while the platform runs from source too. How does the platform find it?
- Symlink into modules/ *(R)*: start links each *.Web folder into the platform's modules folder (the VC docs' 'link the Module Web directory' workflow). On Windows symlinks need Developer Mode or admin; junctions work without
- Platform setting: Point the platform's module discovery path at a folder (if the platform supports more than one, unverified); no links in the platform checkout
- Copy on start: Copy built module output into modules/ each start; no link permissions needed, but a rebuild needs a restart of start

Answer: "Symlink. There are two approaches: symlink individual *.web or whole modules folder". → H2 ✅ (whole-folder target undefined, §2.5)

**Building:** Who builds the source components before they run?
- User/IDE builds *(R)*: start only runs what's there (e.g. dotnet run --no-build fails fast if unbuilt); matches 'dotnet watch build' or IDE workflows and cloud routines building first
- start builds: start runs dotnet build / yarn install + build before launching each source component
- Switch in .env: BUILD_SOURCES=true|false decides

Answer: "User/IDE builds (Recommended)". → H6 ✅

**Combos:** Which Docker/source combinations must work?
- All of them *(R)*: Including storefront in Docker + platform from source: nginx then proxies to the host (host.docker.internal; Linux needs extra_hosts: host-gateway)
- Platform-first only: Frontend from source requires nothing special; Docker storefront + source platform is unsupported (start refuses with a message)

Answer: "All of them (Recommended)". → H7 ✅

### 3.9 P9, 2026-10-15 00:58 UTC

**Optional svc:** How are optional Docker services (Elasticsearch, Kibana) switched off?
- COMPOSE_PROFILES *(R)*: Kibana and Elasticsearch get profiles; COMPOSE_PROFILES=elasticsearch,kibana in .env. Compose-native, consistent with COMPOSE_FILE being the truth
- Separate compose files: docker-compose.elasticsearch.yml / .kibana.yml; listed in COMPOSE_FILE or not. One mechanism for everything
- On/off keys: ENABLE_KIBANA=false etc., translated by scripts; raw docker compose ignores them

Answer: "Separate compose files". → H9 ✅

**Frontend:** What does 'frontend' cover for the Docker-or-source choice?
- Storefront only *(R)*: vc-frontend (Docker nginx image or a source checkout with yarn dev). vc-shell custom apps stay with their module repos (they run via Vite against the platform URL)
- Storefront + vc-shell apps: Also launch vc-shell apps (e.g. a module's Apps/management) from source via a list key

Answer: "Storefront only in docker only. If frontend chosen to be source code, then it's dev responsibility to configure it properly and run via yarn". → H8 ✅

**Front config:** A storefront running from source must point at the platform. How does it get the URL?
- Env var at launch *(R)*: start passes APP_BACKEND_URL (computed from the platform's mode/port/HTTPS) to yarn dev; nothing written into the checkout
- Write .env.local: start writes APP_BACKEND_URL into the checkout's .env.local (gitignored there); IDE / manual yarn dev runs see it too, like user-secrets for the platform

Answer: "See previous answer". → ↪ H8 (no launch, no config)

**ES mode:** Elasticsearch single-node mode (no memory lock, no raised ulimits; needed by cloud VMs and CI):
- Default for everyone *(R)*: It's a single-node dev cluster anyway; one config, no override file. Existing esdata volume compatibility goes on the verify list
- Opt-in override: Local default stays as today; docker-compose.es-single-node.yml added to COMPOSE_FILE when needed

Answer: "Opt-in override". → H10 ✅ (renamed in D1)

### 3.10 P10, 2026-10-15 01:01 UTC

**Multi-stack:** Should two VirtoLocal folders be able to run side by side (e.g. Marketplace and Management stacks)? Today volume names are fixed virto_*, so two folders would share data.
- Yes, per-project volumes *(R)*: Volume names derive from the project (folder) name; migrated folders keep the virto prefix via a .env key. Ports already come from .env
- No: One stack per machine; keep fixed virto_* names

Answer: "Yes, per-project volumes (Recommended)". → D3 ❌ (§2.1, finding 2: image tags stay shared)

**Compose v1:** Docker Compose v1 (legacy docker-compose binary) is still supported by docker-compose-helper.ps1. Keep it?
- Require v2 *(R)*: Preflight check with a clear message; v1 is end-of-life since 2023. Frees COMPOSE_FILE-in-.env, !reset, depends_on conditions
- Keep v1: Features needing v2 degrade or are refused under v1

Answer: "Require v2 (Recommended)". → D4 ✅ (minimum tightened to v2.18.0 for `!reset`)

**Port** (multi-select): Which features from your repo should be ported?
- Health checks + service_healthy: depends_on: condition: service_healthy chains replace the wait-for-it.sh entrypoints
- Redis as pure cache: --save "" --appendonly no --maxmemory; drops the redisdata volume's persistence
- ES heap / memory caps: ES_JAVA_OPTS -Xms/-Xmx tied to ES_MEM_LIMIT, sized for a laptop
- Elasticsearch 9: Default STACK_VERSION to 9.x (your repo runs 9.5.5); existing 8.18 data needs the migration (index reset + reindex)

Answer: "Health checks + service_healthy, ES heap / memory caps, Elasticsearch 9, Check why Redis persisted and tell me. For ES heap/memory caps - let's create optional config or merge with es-single-node (it actually should be named differently, since it's mostly not about single node - check previous conversations to understand why we need it). Elastic 9 probably don't need migration, at I didn't one.". → D5 ✅, D1 ✅, D7 ✅; Redis → P11

**Bind:** Default bind address for published ports?
- 0.0.0.0 + BIND_ADDRESS key *(R)*: Today's behavior by default; set BIND_ADDRESS=127.0.0.1 to restrict to localhost
- 127.0.0.1 default: Your repo's secure default; breaks access from other machines/VMs until BIND_ADDRESS=0.0.0.0 is set

Answer: "127.0.0.1 default". → D9 ✅

### 3.11 P11, 2026-10-15 01:07 UTC

**Redis:** Redis is started, password-protected and persisted, but the platform never connects to it (no RedisConnectionString anywhere). What should happen to it?
- Optional compose file *(R)*: docker-compose.redis.yml, not in COMPOSE_FILE by default; when listed it also sets ConnectionStrings:RedisConnectionString so it's actually used (cache backplane). Cache-only, no persistence. Migrated folders: dropped (it was never used)
- Remove entirely: One instance never needs a backplane; delete the service, volume, port and password
- Keep, wire it up: Always on and actually connected via RedisConnectionString; cache-only, no persistence

Answer: "Optional compose file (Recommended)". → D6 ✅

**ES override:** The ES override is about hosts that cap kernel resource limits (memlock 8 MiB, nofile 20,000, no CAP_SYS_RESOURCE), not single-node. Heap caps are a separate concern, and ES already auto-sizes its heap to ~50% of mem_limit (ES_MEM_LIMIT=1g gives ~512m, same as your repo's -Xmx512m; unverified). How to shape it?
- Rename; no heap file *(R)*: docker-compose.es-capped-limits.yml (single-node, no memory lock, no ulimits). Heap stays automatic via the existing ES_MEM_LIMIT key; verify auto-sizing
- Rename + heap keys: Same file, plus optional ES_HEAP_SIZE key in base compose (empty = automatic) for explicit -Xms/-Xmx
- One 'constrained' file: docker-compose.es-constrained.yml merges capped limits + explicit 512m heap: one switch for small hosts

Answer: "Verify via throwaway, I started docker. If same, drop keys, it not - keep. Rename". → D1 ✅, D2 ℹ️ (verified, keys dropped)

**ES provider:** With ES 9 as the new default, VirtoCommerce has both ElasticSearch8 and ElasticSearch9 modules, but the compose hardcodes Search:Provider=ElasticSearch8. How is the provider chosen?
- Follow STACK_VERSION *(R)*: Major 9 gives ElasticSearch9 settings, 8 gives ElasticSearch8; existing folders on 8.18 unchanged. The installed module set must match (verify the bundles ship ElasticSearch9)
- Separate key: SEARCH_PROVIDER=ElasticSearch8|ElasticSearch9 in .env, independent of the server version (8 client works on 9 via REST compatibility)
- Per-version compose file: docker-compose.es8.yml / es9.yml in COMPOSE_FILE, each carrying image + provider settings

Answer: "Follow STACK_VERSION (Recommended)". → D8 ⚠️ (follows the installed module instead)

**Bind migr.:** You chose 127.0.0.1 as the default bind address. Existing folders reachable from other machines today would lose that. Migration behavior?
- Migrated keep 0.0.0.0 *(R)*: Migration writes BIND_ADDRESS=0.0.0.0 into old .env files; only new folders get 127.0.0.1. No break
- Everyone gets 127.0.0.1: Old folders switch too; release notes say to set BIND_ADDRESS=0.0.0.0 for remote access

Answer: "Everyone gets 127.0.0.1". → D9 ✅

### 3.12 P12, 2026-10-15 01:14 UTC

**HTTPS:** HTTPS default?
- On, HTTP kept *(R)*: New HTTPS ports added (e.g. PLATFORM_HTTPS_PORT); existing HTTP ports keep working; printed URLs and Assets/Content PublicUrl switch to https
- On, HTTP redirects: HTTP ports stay bound but redirect to HTTPS; old bookmarks still land, API clients on http:// may break on POST
- Opt-in: An optional compose file (docker-compose.https.yml) in COMPOSE_FILE; default stays HTTP

Answer: "https and no http by default, on migration or via flag http can be enabled or used instead (probably last one).". → E1 ✅ (with P13)

**Endpoints** (multi-select): Which endpoints get HTTPS?
- Platform: Kestrel in the container (or the source-run platform) serves the cert
- Storefront: nginx in the vc-frontend container gets a 443 listener
- Kibana: Kibana serves TLS with the same cert
- Elasticsearch: Requires turning ES security on (TLS + auth): a setup init container generates the CA, Kibana needs a login, the platform trusts the CA via a mounted ca.crt + SSL_CERT_FILE

Answer: "Platform, Storefront, Kibana, Elasticsearch". → E2 ✅; the `SSL_CERT_FILE` mechanism → E11 ⚠️

**Cert source:** Where does the certificate come from?
- mkcert, else dev-certs *(R)*: mkcert if installed (trusted by every browser incl. Firefox); otherwise dotnet dev-certs https --export-path (the .NET SDK is already a prerequisite)
- dotnet dev-certs only: No new prerequisite; same cert a source-run platform uses with dotnet run. Linux browser trust is partial (verify)
- mkcert only: One more prerequisite on every machine; best trust coverage
- Init-container CA: Generated inside Docker like ES's setup container; no host trust, so browsers warn

Answer: "For ES - like my repo, it's official docs setup (verify by comparing config). For platform - dotnet dev-certs, frontend has it's own in repo I think". → E3 ✅, E4 ✅, E7 ℹ️ (vc-frontend ships none)

**Trust:** Should the scripts install the certificate's trust on the host?
- Interactive only *(R)*: Interactive runs install trust (sudo/admin prompt via mkcert -install or dev-certs --trust); non-interactive runs print the command
- Always: Install trust in every run, including unattended ones (may need elevated rights in CI/cloud)
- Never: Print instructions only

Answer: "Never". → E5 ✅

### 3.13 P13, 2026-10-15 01:18 UTC

**HTTP mode:** HTTPS-only by default. How exactly does HTTP come back?
- Switch: HTTP instead *(R)*: One switch (flag that rewrites .env, or an optional compose file in COMPOSE_FILE) makes the stack HTTP-only instead of HTTPS; never both at once. Migration sets HTTP mode for existing folders so their URLs keep working
- Switch, migration -> HTTPS: Same switch, but migrated folders move to HTTPS too; release notes explain the switch
- Switch: HTTP alongside: The switch adds HTTP next to HTTPS instead of replacing it

Answer: "Switch: HTTP instead (Recommended)". → E1 ✅, E12 ⚠️ (HTTP mode also turns Elasticsearch security off)

**Migr. trigger:** When does migration run?
- Every script *(R)*: Each script calls an idempotent migrate step first; a no-op when the folder is current
- Installer only: Only re-running the installer migrates; other scripts refuse an old layout with 're-run the installer'
- Explicit verb: A migrate script the user runs; others refuse an old layout

Answer: "Every script (Recommended)". → F1 ✅

**Destructive:** Destructive migration steps (dropping Redis volume, ES index reset, volume copy for per-project names): how are they confirmed?
- Confirm interactively *(R)*: Interactive runs ask; non-interactive runs proceed and log what they did
- Automatic + notice: Never ask; print what was done
- Never automatic: Print the commands; the user runs them

Answer: "Confirm interactively (Recommended)". → F2 ✅ (its step list is stale, §2.5)

**Draft:** What happens to the uncommitted draft on feat/non-interactive?
- Discard, new branch *(R)*: Rebuild from dev on a new branch; keep docker-compose.es-single-node.yml and scripts/reset-admin-password.ps1 as reference until replaced
- Evolve it: Keep working on feat/non-interactive and reshape it

Answer: "Already stashed, reuse branch since now on same commit as dev". → F3 ✅

### 3.14 P14, 2026-10-15 01:24 UTC

**Store cert:** The Docker storefront's nginx needs an HTTPS certificate (vc-frontend ships none). Where from?
- Reuse the dev-certs export *(R)*: Same localhost PEM the Docker platform mounts; one cert for both, trusted wherever the user trusted dotnet dev-certs
- From the ES setup CA: setup container issues a 'storefront' cert next to ES/Kibana; one CA for all Docker services, but browsers won't trust it (no trust install)
- mkcert, like vc-frontend dev: Matches vc-frontend's dev server tooling; adds mkcert as a prerequisite

Answer: "Reuse the dev-certs export (Recommended)". → E8 ✅; the bind-mount delivery ("mounts") → E10 ⚠️

**Kibana cert:** Kibana serves HTTPS (your repo's hardening, beyond the official setup). Which cert?
- ES setup CA, like your repo *(R)*: instances.yml gets a kibana entry; the setup healthcheck waits for both certs. Browser warns unless the user trusts the CA
- dev-certs export: Same localhost cert as platform/storefront: one browser trust covers all three UIs

Answer: "It's not my hardening, it was official at least for ES 8. Re-check. But in general - yes, ES CA". → E9 ✅, E3 ℹ️ (the official compose serves Kibana over HTTP in 8.0–8.19)

**Delivery:** How is the work delivered to VirtoCommerce/start-local?
- Staged PRs *(R)*: 1) release/1.0 cut + bootstrap/zip/releases; 2) .env.example + COMPOSE_FILE + migration; 3) source/Docker hybrid; 4) HTTPS + ES security; 5) extras (healthchecks, Redis file, capped-limits, ES 9)
- One PR: Single large PR with the whole redesign
- Two PRs: Releases/bootstrap first (unblocks release/1.0), then everything else

Answer: "I think two or even just creation of release/1.0 + PR, but let's watch how much it grows". → F4 ✅

**Spec home:** Where does the design spec live? (start-local gitignores /docs/*, so this decision log is untracked right now.)
- start-local, un-ignore docs *(R)*: Remove /docs/* from start-local's .gitignore; decision log + spec ship with the code they describe
- start-local, force-add: Keep the ignore rule; git add -f these files
- VirtoOZ Management repo: docs/specs/ in vc-module-virtooz-management with the cloud-stack toolkit todo; start-local gets only code

Answer: "start-local, un-ignore docs (Recommended)". → F5 ✅

### 3.15 P15, 2026-10-15 01:28 UTC

**First-class** (multi-select): Which other old parameters stay first-class (no obsolete warning; they override .env)? Unselected ones become obsolete shims.
- -vcSolutionVersion + -custom*: -vcSolutionVersion, -customPackagesJson, -customFrontendUrl: the main 'what to install' choice, handy on the command line and in cloud routines
- -elasticsearchVersion: Rewrites STACK_VERSION (and with it the ES8/ES9 provider, D8)
- -skipSampleData: Step switches are per run (C2), so this is the natural carrier for the sample-data step; the [bool] type stays (build calls start with it)

Answer: "-vcSolutionVersion + -custom*, -skipSampleData, + new skip per part (platform/frontend/elasticsearch/etc.) - by "grouping" in previous conversation I meant like under comment section in code, not merge into one arg". → B5 ✅, B6 ✅ (`-elasticsearchVersion` becomes a shim)

**Shim life:** How long do the obsolete shims live?
- Until the next minor *(R)*: Present in 1.x after the redesign lands... removed in the next minor release branch; release notes announce it
- Until 2.0: Removed only at the next major release
- Forever: Never removed; they just warn

Answer: "N/A now, create them but don't decide lifecycle". → B1 ✅ (open on purpose)

**HTTP switch:** What should the HTTP-instead-of-HTTPS switch be called?
- -http *(R)*: Short switch on the installer/start; rewrites .env (COMPOSE_FILE gets the HTTP variant). -http:$false goes back to HTTPS
- -protocol http|https: Explicit value, symmetric, slightly longer
- Only a .env key: No parameter: edit COMPOSE_FILE / a PROTOCOL key; migration sets it for old folders

Answer: "-insecure-http or something, check existing args/env vars". → B7 ✅ (`-allowInsecureHttp`, after the platform's `VirtoCommerce:AllowInsecureHttp`)

### 3.16 Chat question, 2026-10-15 01:34 UTC

**Skip switches:** should `-skipElasticsearch` and the others persist into `COMPOSE_FILE` (like `-dbProvider`) or apply to one run only?

Answer: "1. Persist". → B6 ✅
