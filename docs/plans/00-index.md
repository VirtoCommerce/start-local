# Implementation Plans Index

> Dated, phased implementation checklists. The design rationale for a plan lives in `docs/specs/` under the same slug; plans here hold the steps.
>
> **Historical per implemented task, living otherwise.** Once a task's commit lands, corrections to it go in a dated *Task N amendments* block right after that task, with the original left intact. Tasks not yet implemented, and the plan-wide sections, are overwritten in place.

## Files (newest first)

| Date | Plan | Topic | Status | Spec |
|------|------|-------|--------|------|
| 2026-11-10 | [env-first-redesign](2026-11-10-env-first-redesign.md) | 20 tasks in 6 phases: `.env` core and Pester (A), HTTP-mode stack and scripts (B), HTTPS (C), source mode (D), installer (E), CI (F). Read before executing the redesign or changing its scripts | ❌ not built | [env-first-redesign](../specs/2026-10-15-env-first-redesign-design.md) |

## Conventions & Writing Style

- Naming: `YYYY-MM-DD-<slug>.md`, reusing the paired spec's slug. Tasks are `### Task N: …`, and steps are `- [ ]` checkboxes.
- Everything the executor needs beyond a task's own text sits before the first `## Phase` heading: constraints, decisions `P#`, user steps `F#`. Tasks cite these by ID.
- Each task carries a `Reads:` line, an `Interfaces:` block with exact PowerShell signatures, and a test-first step sequence.
- The task list ends with the last feature task. Review and verification run once each, as later lane phases.

## Notes & Caveats

- The Status column reflects the code as of the plan's verification date: ✅ implemented · ⚠️ partial · ❌ not built · ♻️ superseded.
- **env-first-redesign** marks steps that verify an unverified fact from SPEC §15 as "stop and report". A failure at such a step goes back to `/sdd-design`, not to an in-place fix.
