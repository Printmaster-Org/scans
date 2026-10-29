# Agent Instructions

This is the standalone PrintMaster Scans utility. Read [README.md](README.md) for supported platforms, development, testing, and release deployment. The utility is `src/scans.ps1`; the root `scans.ps1` is the release loader, not the utility.

## Keep the docs site in sync (required)

- The canonical documentation lives in **Printmaster-Org/docs.printmaster.work**, normally checked out at `../docs.printmaster.work`. The main Scans guide is [content/scanning/printmaster-scans.md](../docs.printmaster.work/content/scanning/printmaster-scans.md), published at `/guides/scans/`.
- Review documentation impact for every feature, fix, removal, and deprecation. Changes to behavior, setup options, password handling, supported platforms, UI, loaders, or releases must update affected canonical pages in the same task. Keep this repository's README and deployment notes accurate too, without duplicating full guides.
- Follow the docs repository's [README](../docs.printmaster.work/README.md) for editing and validation. Link implementation and documentation commits or PRs, and report the updated pages and validation. Distinguish development changes from published releases: merging utility code does not deploy it to users.
- If no documentation change is needed, explicitly explain why. If the docs checkout is unavailable, report the blocker and exact pages needing updates; do not silently leave docs stale or report the task as complete.

## Commits and validation (required)

- Direct, fast-forward pushes to `main` are permitted. Feature branches and pull requests are optional. Validate changes before pushing; never force-push shared history.
- Use Conventional Commit subjects such as `fix(scans): retry rejected account passwords`. Include a `Docs:` reference to the paired docs commit or PR, or an explicit no-impact reason.
- Run the relevant tests described in the README before submitting. Keep machine-changing operations mocked in automated tests; validate real setup only on a disposable Windows VM.
- Do not publish a release or deploy the website unless explicitly requested. Follow [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for release and deployment changes.
