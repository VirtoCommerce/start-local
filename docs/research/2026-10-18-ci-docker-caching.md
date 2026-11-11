# Docker image and build caching on GitHub Actions

Date: 2026-10-18. Optimizations for the start-local CI smoke test (decision G1 in the [decision log](../specs/2026-10-15-redesign-decisions.md)), whose runners are described in the [review follow-up](2026-10-18-redesign-review-follow-up.md) §5 and *Amendments*. Nothing here is decided or implemented yet.

Sources are docs.github.com, docs.docker.com, the READMEs of the `docker/*` and `actions/cache` actions, and the GitHub changelog, read by a research subagent. The two claims the recommendations rest on (Docker Hub limits and the `gha` backend's driver support) were re-read from the source pages.

## The stack under test

- **Pulled images:**
  - from Docker Hub: `postgres:18.3` (or `mysql:9.3`), `redis`, and the nginx base;
  - from Elastic's registry: `docker.elastic.co/elasticsearch/elasticsearch:9.5.5` and Kibana 9.5.5, over 1 GB each;
  - from Microsoft's registry: `mcr.microsoft.com/mssql/server:2022-latest`.
- **Built images:**
  - `vc-platform`: `FROM mcr.microsoft.com/dotnet/aspnet:10.0`, plus a `COPY` of the platform and modules that `vc-build install` downloads first. Today's build script runs it as `docker build --no-cache`.
  - `vc-frontend`: nginx plus a downloaded storefront zip.
- **Runners:**
  - `ubuntu-24.04`: native Docker 28.0.4.
  - `windows-2025`: Docker inside a WSL2 distribution that the job installs.
  - `macos-15-intel`: colima.

  The Windows and macOS daemons start empty in every job.

## Summary

| # | Question | Verdict | Impact |
|---|----------|---------|--------|
| 1 | Docker Hub rate limits on hosted runners | Confirmed (docs) | None apply; no `docker login` needed |
| 2 | Images pre-cached on runner images | Confirmed (docs) | None; every image is pulled |
| 3 | `docker save` / `load` of pulled images through `actions/cache` | Not recommended anywhere; community evidence says pulling is faster | Don't cache pulled images |
| 4 | BuildKit `gha` cache with the default `docker` driver | Confirmed (docs) | Needs the containerd image store, which Ubuntu's Docker 28 lacks. Use a `docker-container` builder |
| 5 | `actions/cache` limits | Confirmed (docs) | 10 GB per repository, 7-day eviction |
| 6 | Build cache from the WSL2 and colima daemons | Unverified | Measure before relying on it |

## 1. Docker in Actions and Docker Hub limits

- Service containers and job containers need Linux runners: "If your workflows use Docker container actions, job containers, or service containers, then you must use a Linux runner" ([service containers](https://docs.github.com/en/actions/tutorials/use-containerized-services/use-docker-service-containers)). On Windows and macOS, the scripts' own `docker compose` is the only option.
- "Docker Hub normally imposes rate limits on both push and pull operations which will affect jobs on self-hosted runners. However, GitHub-hosted runners are not subject to these limits based on an agreement between GitHub and Docker" ([run jobs in a container](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/run-jobs-in-a-container); re-read). Elastic's and Microsoft's registries aren't Docker Hub anyway.
- GitHub's docs give no guidance on caching pulled images. Neither the dependency-caching page nor the service-container page mentions them.
- The Ubuntu 24.04 (20261012.334.1) and Windows 2025 (20261013.288.2) image READMEs have no "Cached Docker images" section.

## 2. Build cache for the built images

**The `gha` backend:**
- On driver support: "This cache storage backend works with the default `docker` driver only when the containerd image store is enabled. If the containerd image store isn't enabled, use a different driver" ([gha backend](https://docs.docker.com/build/cache/backends/gha/); re-read).
- The containerd store is the default only on fresh installs of Engine 29.0+ ([containerd image store](https://docs.docker.com/engine/storage/containerd/)). The Ubuntu runner has Docker 28.0.4, so a plain `docker build --cache-to type=gha` there most likely fails.
- The portable route is `docker buildx create --driver docker-container --use`, then `--load`, so that Compose sees the result.
- From a script, the cache variables (`token` defaults to `$ACTIONS_RUNTIME_TOKEN`, `url_v2` to `$ACTIONS_RESULTS_URL`) "must be manually exposed" when `docker buildx` is invoked from an inline step. The page suggests `crazy-max/ghaction-github-runtime`, which exports every `ACTIONS_*` variable (re-read).
- The cache scope is shared by default: "If you build multiple images, each build will overwrite the cache of the previous". Use `scope=vc-platform` and `scope=vc-frontend`, with `mode=max`.
- The cache API throttles requests ("ERROR: maximum timeout reached"). Passing `ghtoken` and `repository` mitigates it.

**Other backends:**
- `type=inline` "only supports `min` cache mode" ([GitHub Actions cache](https://docs.docker.com/build/ci/github-actions/cache/)).
- `type=local` with `actions/cache` keeps growing unless `reset=true` is set, which needs Buildx 0.35.0 or later. Ubuntu has 0.38.0.
- `type=registry`, for example on GHCR, is the remaining option. It wasn't evaluated further.

**Compose:**
- `build.cache_from` / `cache_to` accept `type=gha` ([compose build](https://docs.docker.com/reference/compose-file/build/)). But "Unsupported caches are ignored and don't prevent you from building images", so on the default builder no cache is written and no error is shown.
- `docker/build-push-action` with `load: true` is shorthand for `--output=type=docker`, so a later Compose step can use the image. The action fills in the cache URL and token itself.

**The platform image:** its large layer is the `COPY` of the platform and modules, which changes whenever the modules change. So a build cache mostly saves the base and storefront layers.

## 3. Caching pulled images

- No GitHub or Docker doc recommends `docker save` / `docker load` through `actions/cache`.
- `oughtinc/action-docker-layer-caching` README: "avoid caching pull-only images. (docker pull is faster than caching in most cases.)". A community benchmark (dev.to/dtinth) reports that `docker save` is very slow. Neither was re-measured here.
- Mirroring images into GHCR costs nothing inside Actions: "Container image storage and bandwidth for the Container registry is currently free" (GitHub Packages billing). Whether GHCR pulls are faster than `docker.elastic.co` is unmeasured.
- Registry mirrors:
  - For builds only, through `buildkitd-config-inline` (`mirrors = ["mirror.gcr.io"]`).
  - For the daemon, through `docker/setup-docker-action` `daemon-config`. That action "Works on Linux, macOS and Windows" but "Does not work on macOS runners with ARM architecture".

## 4. `actions/cache` limits

From [dependency caching](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching):
- "By default, the limit is 10 GB per repository".
- Caches not accessed for 7 days are removed.
- Runs can restore caches from the current branch or the default branch. PR runs can also restore from the base branch, and caches made by PR runs are scoped to the merge ref.
- Caches are OS-specific unless `enableCrossOsArchive` is set.
- No per-entry size limit is documented.

From the GitHub changelog:
- 2025-11-20: repositories can exceed 10 GB "using a pay-as-you-go model". This needs a Pro, Team or Enterprise account; when the budget runs out, the cache becomes read-only.
- The v2 cache service rolled out from 2025-02-01, and the legacy service is retired. `actions/cache` needs v4.2.0 or v3.4.0 at minimum; v5+ needs runner 2.327.1 or newer.

## 5. The Windows (WSL2) and macOS (colima) lanes

No docs cover either. These are inferences, unverified:
- **WSL2:** `wsl docker buildx …` doesn't inherit `ACTIONS_RUNTIME_TOKEN` or `ACTIONS_RESULTS_URL`. They would have to be forwarded through `WSLENV`, or passed as `url_v2=` / `token=`.
- **WSL2:** a `type=local` cache directory inside the WSL filesystem is invisible to the host's `actions/cache` unless it lives under `/mnt/c/...`.
- **colima:** the Docker CLI runs on the host and inherits the environment, so the `gha` backend should work. Whether the VM can reach the cache service is untested.

## 6. Other optimizations

- `docker compose pull` has `--quiet`, `--ignore-buildable` and `--policy missing`. Whether it pulls in parallel by default is unverified.
- Cancel superseded runs with `concurrency: { group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: true }` (GitHub docs example).
- Skipping docs-only changes: when a **required** check's workflow is skipped by a path filter, its checks "will remain in a 'Pending' state". Use a job-level `if:` or a paths-filter step instead of `paths-ignore`.
- `--no-cache` has no effect across jobs while every lane starts with an empty daemon. It matters only once a remote cache is wired.

## Recommendations

None is adopted; they are input for when CI is implemented.

1. **Cache the vc-build download folder and the NuGet cache** with `actions/cache`, keyed on the package manifest and platform version, separately per OS. It is the largest download on every lane. On Windows, keep the folder where both Windows and WSL reach it (`/mnt/c/...`).
2. **Cancel superseded runs, and skip docs-only changes** with a job-level `if:` rather than `paths-ignore`. This saves whole runs on every lane.
3. **Start `docker compose pull --quiet --ignore-buildable` in the background early**, overlapping the vc-build download. Expect a few minutes saved, most on Windows and macOS.
4. **BuildKit `gha` cache on Ubuntu:** a `docker-container` builder, `--load`, a scope per image, `mode=max` and `ghtoken`. The payoff is moderate. It needs build to stop passing `--no-cache` and to accept cache options, for example through an environment variable. Extend it to Windows and macOS only after a probe.
5. **Mirror the Elastic images into GHCR** only if pulls from `docker.elastic.co` prove slow.

Discouraged:
- `docker save` / `load` of pulled images through `actions/cache`.
- `type=inline` where `mode=max` is wanted.
- `type=local` without `reset=true`.
- Relying on Compose `cache_to` with the default builder.
- `docker login` only to avoid rate limits.
