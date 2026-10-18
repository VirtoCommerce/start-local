# Research Notes Index

> Dated investigations (findings, library behavior, trade-offs) that informed a decision, usually the precursor to a spec of the same topic.
>
> **Historical / append-only.** A note reflects what was understood on its date; never rewrite a finding. Corrections and outcomes go in a dated *Amendments* / *Outcome* section, original intact. Check conclusions against the current tree, or the matching spec, before relying on them.

## Files (newest first)

| Date | Note | Topic | Related |
|------|------|-------|---------|
| 2026-10-18 | [ci-docker-caching](2026-10-18-ci-docker-caching.md) | Docker image and build caching on GitHub Actions for the CI smoke test: what to cache, what not to, and on which runners. Read before implementing CI | [env-first-redesign](../specs/2026-10-15-env-first-redesign.md) |
| 2026-10-18 | [redesign-review-follow-up](2026-10-18-redesign-review-follow-up.md) | Facts behind the 2026-10-18 review changes: per-folder platform config, HTTPS overlays, release channel names, autostart, GitHub runner capabilities. Read before changing source-run config, HTTPS files or CI | [env-first-redesign](../specs/2026-10-15-env-first-redesign.md) |
| 2026-10-15 | [redesign-fact-check](2026-10-15-redesign-fact-check.md) | Facts behind the env-first redesign: GitHub URL and release behavior, Compose `.env`/`COMPOSE_FILE`/`!reset`, Elasticsearch single-node, heap and upgrade, the DB password bug, search modules and bundles, dev-certs/Kestrel/trust, user secrets, symlinks, Docker Desktop file sharing, prior-art installers. Read before changing install, Compose or TLS behavior | [env-first-redesign](../specs/2026-10-15-env-first-redesign.md) |

## Conventions & Writing Style

- Naming `YYYY-MM-DD-<kebab>.md`. Exploratory tone: evidence, citations, conclusions.
- Give each finding a verdict (Confirmed / Partial / Unverified). Mark *live* when it was tested, and state the environment it was tested in.

## Notes & Caveats

- **redesign-fact-check** was tested on one machine (Ubuntu 24.04, Docker Desktop, Compose v5.5.1). Windows behavior, especially directory junctions and `COMPOSE_PATH_SEPARATOR`, is inferred from docs, not tested.
- **redesign-review-follow-up** §5 describes GitHub runners from their image READMEs; its *Amendments* hold the live probe results. IDE working directories for the per-folder settings file are unchecked.
- **ci-docker-caching** recommendations are not adopted yet. Build cache on the WSL2 and colima lanes is inferred, not tested.
