# scan-it

Open-source ScanSnap iX500 document-scanning stack for macOS: SANE-driven bash CLIs that turn ADF paper stacks into dated, ordered PDFs over USB — built because Fujitsu/PFU dropped ScanSnap Manager on modern macOS.

## TL;DR

- **What:** Restores a full scan-to-PDF workflow for the Fujitsu ScanSnap iX500 on current macOS using only open-source software, over USB.
- **How:** SANE's `scanimage` drives the scanner; the CLI tools in `bin/` handle acquisition, PDF assembly, check normalization, and manifest-driven filing.
- **Stack:** bash · SANE/sane-backends · img2pdf + qpdf · ImageMagick + poppler · jq · optional ocrmypdf · NAPS2 (GUI). No build step. bun runs the live dashboard; its `package.json` only holds dev tooling and task shortcuts.
- **Install:** symlink `bin/*` onto your `PATH` (they already live in `~/bin` on this machine).
- **Run it:** `scan-batch` scans a mixed stack into local staging; Claude classifies each sheet and writes a manifest; `batch-file` files every document into the Google Drive filing root `~/My Drive/scans/<entity>/<type>/[<YYYY>/]`.
- **Read side:** `scan-catalog` merges the sidecars into a catalog, lists open follow-ups (Drive copies, QuickBooks drafts, calendar reminders, medical records), and renders the HTML dashboards.
- **Live dashboard:** `scan-catalog serve` runs a local server on http://127.0.0.1:7820/ with scanner status, batches in progress, and buttons that run the tools (scan, stop, resume, file, diagnose, restart the Brother services).
- **Run and deploy:** `bun run dev` serves the dashboard with mock scanners on http://127.0.0.1:7830/ and restarts on edits; `bun run deploy` puts this checkout live at https://scans.beric.ca and on the tailnet. See "Run locally and deploy".
- **Diagnose:** `scan-diag` runs every dependency check and prints pass/fail with a fix hint per failure.

## Overview

Fujitsu/PFU discontinued ScanSnap Manager support on recent macOS, leaving the iX500 without vendor software. `scan-it` replaces it entirely with the open-source SANE stack plus a set of small, composable bash tools. There is **no application to run** — the tools are ordinary CLIs you invoke against a stack of paper in the automatic document feeder (ADF).

Three workflows are supported:

1. **Plain documents** — `scan2pdf` acquires an ADF stack into one dated multi-page PDF.
2. **Paychecks** — `scan-checks` / `checks-split` / `checks-normalize` / `checks-report` produce one uniform, check-number-ordered PDF per paydate, capturing front + endorsement back.
3. **Mixed batches** — `scan-batch` continuously scans a heterogeneous stack into per-page images; a reader (Claude) classifies each page and writes a JSON manifest; `batch-file` validates it and files every document into typed folders with JSON sidecars.

A GUI path (NAPS2) is also documented for point-and-click scanning.

## Tech stack

- **bash** — every tool except scan-organize (python3 stdlib), `set -euo pipefail`. No compiled code, no dependencies bundled.
- **bun** — runs `share/server.ts`, the live dashboard server behind `scan-catalog serve`. Only that command needs it. `bun install` adds `typescript` and `@types/bun` for `bun run typecheck` (strict); nothing at runtime depends on them.
- **SANE / sane-backends** — `scanimage` (acquisition) and `sane-find-scanner` (probe); the `fujitsu` backend drives the iX500 over USB.
- **img2pdf** — assemble page images into PDFs (the primary assembler).
- **qpdf** — page-level PDF merge / split / append without re-encoding existing pages.
- **ImageMagick** (`magick`) — check normalization: guarded backing trim, deskew, rotate portrait backs to landscape.
- **poppler** (`pdftoppm`) — render PDF pages back to images for the normalization pass.
- **jq** — parse and validate the JSON manifests that drive `batch-file` and `checks-split`.
- **ocrmypdf** — *optional* searchable text layer on filed PDFs (filing works without it).
- **NAPS2** (`/Applications/NAPS2.app`) — GUI scanning via the SANE driver.
- **bats** — dev-only test suites under `test/` (not required to run the tools).

All runtime dependencies are CLI tools installed via Homebrew; the repo itself ships only bash scripts.

## Getting started

### 1. Install dependencies

```sh
brew install sane-backends img2pdf qpdf imagemagick poppler jq
brew install ocrmypdf          # optional: searchable text layer on filed PDFs
brew install --cask naps2      # optional: GUI scanning path
```

Ensure the `fujitsu` backend is enabled in SANE:

```sh
grep -n fujitsu "$(brew --prefix)/etc/sane.d/dll.conf"   # must exist, uncommented
```

### 2. Install the tools

There is no installer — the tools are symlinked from `bin/` onto your `PATH`:

```sh
mkdir -p ~/bin
for f in "$PWD"/bin/*; do ln -sf "$f" ~/bin/; done   # ensure ~/bin is on PATH
```

### 3. Verify the stack

```sh
scan-diag        # USB presence, toolchain, SANE probe, backend, conflicting software
```

Green across the board means you're ready. See `TROUBLESHOOTING.md` for any failure, and `ENVIRONMENT.md` for the recorded machine/scanner baseline.

### 4. Scan

```sh
scan-batch                            # → ~/.cache/scan-it/batches/batch-<ts>/ (local staging)
batch-file <staging-dir>              # → ~/My Drive/scans/<entity>/<type>/...
scan2pdf taxes                        # raw one-off → ~/My Drive/scans/_inbox/taxes-<ts>.pdf
```

### Configuration

- **Filing root:** `SCAN_ROOT`, default `~/My Drive/scans` (Google Drive). Layout: `<entity>/<type-folder>/[<YYYY>/]<name>.pdf` plus a `.json` sidecar; year folders for receipts, invoices, statements, taxes (tax year) and paychecks. Also `_review/`, `_index/<user>@<host>.jsonl` (one append-only log per filer, so two machines never write one file), `_inbox/` (raw `scan2pdf` output), `_originals/` (`scan-organize` sources), and `dashboard.html` at the root and in each entity folder.
- **Staging:** `SCAN_STAGING`, default `~/.cache/scan-it/batches`. Page JPEGs stay off Drive.
- **Registries in the filing root:** `entities.json` (slug, legal name, kind, aliases, notes, `"quickbooks": true`, and `"copies": {"tax": "8328 De Soto Ave/Tax/{year}/Tax Supporting Docs"}` paths relative to the Drive root, `SCAN_DRIVE_ROOT`, default the filing root's parent) and `profiles.json` (users with login accounts, scanners, and per user+scanner profiles carrying a `default_entity`).
- **Scan defaults:** duplex, color, 300 dpi; flip with `-s` (simplex), `-g` (gray), `-r N` (dpi).
- **`scan-batch` env vars:** `SCAN_BATCH_SCANIMAGE` (path to `scanimage`), `SCAN_BATCH_POLL_SECS` (paper-sensor poll interval, default 2), plus `--idle N` (end batch after N idle seconds, default 60).
- **Live server:** `scan-catalog serve --install` keeps it running at login as the LaunchAgent `ca.beric.scan-it-dashboard` (log `~/Library/Logs/scan-it-dashboard.log`; `--uninstall` removes it and the tunnel agent). For other devices see "Reaching it from other devices" below; `bun run deploy` installs it with every flag that needs. Run by hand: `scan-catalog serve --port N` (default 7820), `--no-open`, `--mock` (or `SCAN_SERVE_MOCK=1`: simulated scanners, batches and jobs). It honors `SCAN_ROOT`, `SCAN_STAGING`, `SCAN_DASHBOARD_TEMPLATE`, `SCAN_BATCH_ESCL` and `SCAN_BATCH_SCANIMAGE`. Job logs go to `<staging>/.logs/`, page thumbnails to `<staging>/.thumbs/`.
- **Who and what:** `scan-batch --user <slug>` (or `SCAN_USER`, or an account match in `profiles.json`) and the detected scanner go into `batch.json` and from there into every sidecar.

## Scripts / commands

All live in `bin/` and are symlinked onto `PATH`.

| Tool | What it does |
|------|--------------|
| `scan2pdf` | Scan an ADF stack to a dated multi-page PDF. Duplex/color/300 dpi by default; `-s` simplex, `-g` gray, `-r N` dpi, `-o DIR` outdir, `-p` lossless PNG intermediates, `-k` keep page images, `-x ARG` pass-through to `scanimage`, `--open` opens the PDF. Exit codes: `0` success · `1` no scanner · `2` empty ADF · `3` PDF assembly failure. |
| `scan-checks` | Scan employee paychecks duplex (front + endorsement back) into one PDF per paydate (`checksYYYYMMDD.pdf`), pages in check-number order. Wraps `scan2pdf`; re-running a paydate appends, `--replace` starts over, `--staging` scans an unsorted stack for the manifest workflow. |
| `checks-split` | Split a duplex staging PDF into per-paydate PDFs from a manifest (front/back page, check number, date, rotations), sorted by check number and validated before writing. Normalizes each check individually before assembly, so output pages are already uniform; appends to existing paydate PDFs without re-encoding their pages. |
| `checks-normalize` | Make check pages uniform: guarded scanner-backing trim (border must read as backing, box must be sheet-sized, crop must remove ≥15%), deskew, rotate portrait backs to landscape (bank-image convention). `--page <in> <out.jpg> <front\|back>` normalizes one rendered page (used by `checks-split`); PDF mode rebuilds an existing PDF in place, passing already-normalized pages through untouched so re-runs are stable. |
| `checks-report` | Per-paydate summary from a data file (`<check_number> <paydate> <amount> <signed>`): check counts, number sequences, missing numbers, period totals, unsigned checks, grand total. `-o FILE` also writes the report to a file. |
| `scan-diag` | Diagnostics for the iX500 + SANE stack — colored pass/fail summary with a fix hint per failure. Read-only; safe to run any time. |
| `scan-batch` | Continuously scan a heterogeneous stack in chunks (paper sensor auto-resumes between chunks; press Enter or wait for `--idle` seconds to end). Pages accumulate as per-page JPEGs in a timestamped staging dir. Exit codes: `0` success · `1` no scanner / device lost / jam · `2` no pages · `64` usage · `66` bad `--resume` dir · `130` interrupted. |
| `batch-file` | Validate, rotate, merge, rename, and file the staged pages produced by `scan-batch`, driven by `<staging>/manifest.json`. Writes nothing unless every scanned page is accounted for exactly once and every document has an entity. Files entity first, writes sidecars (fields, OCR text, scanner/user provenance, follow-ups), runs the Drive copies `entities.json` maps, writes paydate check reports, appends the per-filer index, refreshes the dashboards. `--no-text-layer`, `--no-dashboard`, `--keep-staging`, `--drive-root DIR`, `-o DIR`. Exit codes: `0` success · `1` validation failure · `2` assembly failure · `64` usage · `66` not a staging dir. |
| `scan-catalog` | Read side of the filing tree. `build [--entity SLUG]` prints the merged catalog (no OCR text); `pending [WORKFLOW] [--json]` lists open follow-ups (`copy`, `quickbooks`, `calendar`, `vault`, `check_report`); `mark <file> <workflow> <status>` records an outcome in the sidecar; `dashboard [--open]` renders `share/dashboard.html` into the root and each entity folder; `serve [--port N] [--no-open] [--mock] [--public-url URL --allow-login LOGINS] [--edge-url URL --edge-allow EMAILS [--edge-port N]]` runs the live dashboard (see below). |
| `scan-tunnel` | `scan-tunnel HOST [PORT]`: reverse SSH tunnel that puts the live dashboard on HOST's loopback for `tailscale serve` there. Frees a port a dead session still holds, then runs `ssh -N -R` in the foreground. `scan-catalog serve --install --tunnel HOST` runs it at login. |
| `scan-organize` | Split an already-scanned PDF into per-document PDFs from a plan JSON (python3 stdlib); moves the source into `_originals/`. |
| `escl-scan` | Direct eSCL client for the Brother ADS-4300N through the Push Scan Tool's localhost bridge. Runs `jpeg-check --repair` on each page as it lands and lists damaged pages in `<outdir>/.damaged` (`ESCL_SCAN_CHECK=0` turns that off). |
| `jpeg-check` | `jpeg-check [--repair] FILE...` (bun). Reads a scanner JPEG's restart markers without decoding: `ok`; `truncated` (the paper ended before the requested height, which the Brother still declares; `--repair` crops it losslessly with jpegtran); `damaged` (the marker sequence skips, so rows are missing mid-page: rescan); `unknown` (no markers, left alone). Exit codes: `0` nothing damaged · `4` a damaged file · `1` unreadable or crop failed · `64` usage. |

### Paycheck workflow

**Mixed / unsorted stack** (the usual case):

```sh
scan-checks --staging                 # any order, orientation, or side
# A reader writes a manifest, one line per check:
#   <front_page> <back_page> <check_number> <YYYYMMDD> <front_rot> <back_rot>
checks-split <staging.pdf> <manifest> # → checksYYYYMMDD.pdf per paydate, each check normalized
```

**Single known paydate, pre-sorted stack:**

```sh
scan-checks 2026-06-05                # → checks20260605.pdf directly
checks-normalize checks20260605.pdf   # raw (never-split) scans still need this pass
```

The sort is physical: stack checks face up, lowest number on top, then flip the whole stack face-down into the feeder, top edge first (the iX500 feeds from the bottom).

### Mixed-batch workflow

```sh
scan-batch                            # feed in chunks; auto-resumes; Enter / idle ends it
# A reader classifies each page and writes <staging>/manifest.json
batch-file <staging-dir>              # validates, files each document, refuses on any gap
```

Output lands under `~/My Drive/scans/<entity>/` in typed folders (`receipts/`, `invoices/`, `contracts/`, `statements/`, `letters/`, `medical/`, `taxes/`, `misc/`, `paychecks/`), year folders where the type has one, review items in `_review/`. Each PDF has a `.json` sidecar (OCR text, extracted fields, scanner/user provenance, follow-ups). Then `scan-catalog pending` lists the follow-ups and `scan-catalog dashboard` renders the dashboards.

### GUI: NAPS2

`/Applications/NAPS2.app`. One-time profile: Profiles → New Profile → Driver **SANE** → device **ScanSnap iX500** → ADF Duplex, 300 dpi, Color → save as default. Then stack → Scan → Save PDF.

## Architecture

Each tool is a self-contained bash script (`set -euo pipefail`) that shells out to the CLI stack — nothing is imported or linked. Data flows in one direction:

```
paper → scanimage (SANE) → page images → img2pdf/qpdf → PDF
                                    ↘ (checks)  pdftoppm → magick normalize → qpdf assemble
                                    ↘ (batch)   staging dir → manifest.json (jq) → batch-file → typed folders + sidecars
```

- **Deterministic vs. judgement.** The bash tools do only deterministic work — acquisition, geometry, PDF assembly, validation, filing. Anything requiring reading a page (which paydate a check belongs to, what type a mixed-batch page is) is delegated to a reader that emits a **JSON manifest**; the tools never guess. `batch-file` and `checks-split` refuse to write unless the manifest fully accounts for every scanned page.
- **Guarded transforms.** `checks-normalize` only ever removes backing/edge fuzz, never content: trims run under multiple guards (border must read as gray backing, box sheet-sized, crop ≥15%, edge cleanup keeps ≥97% of both dimensions), and pages with nothing to trim pass through untouched — so re-runs are idempotent.
- **Device discovery.** The SANE device name embeds the scanner's serial; tools auto-discover it via `scanimage -L` on each run, so a changed serial only matters for hand-typed commands.
- **State on disk.** No database — filing state is the filesystem: typed folders, per-document `.json` sidecars, `entities.json`, and an append-only `index.jsonl`.

### Live dashboard server

`share/server.ts` (bun, no dependencies) serves the dashboard template with the catalog and a live config injected, and adds a JSON API the page polls:

- `GET /api/status`: scanners (eSCL `ScannerStatus` via `escl-scan --status` and `pgrep` of the Brother services; `scanimage -L` and `-A` for the iX500; `ioreg` for USB presence; cached 5 s, skipped for a scanner mid-batch), staged batches with their state and allowed actions, and jobs.
- Batch state comes from the staging dir: a live `.pid` means scanning (`.stop` present: stopping), else `.filed` means filed, else `manifest.json` means ready, else staged.
- `POST /api/scan`, `/api/batches/<id>/{stop,resume,file,discard,reveal}`, `/api/diag`, `/api/brother/restart`, `/api/dashboard/refresh` start the matching tool as a detached job. The server checks each action against the batch state first, and allows one Brother restart at a time (Diagnose waits for it too). Discard moves the staging dir to `~/.Trash`.
- `GET /files/<path>` serves PDFs from the filing root only; `GET /api/batches/<id>/thumb/<n>` serves a `sips` thumbnail.
- Local only: it binds 127.0.0.1, refuses other Host headers (DNS rebinding) and cross-origin POSTs, and every POST must carry the per-launch token the page embeds. With `--edge-url` it opens a second loopback listener for the Cloudflare tunnel (below).

#### Reaching it from other devices

The server never listens on the network. Two routes reach it, and `bun run deploy` sets up both:

| URL | Path | Who gets in |
|---|---|---|
| https://scans.beric.ca | beric.ca edge gate (Cloudflare Worker), then the `beric-mac` Cloudflare tunnel on this Mac to the edge listener, 127.0.0.1:7821 | the beric.ca sign-ins in `--edge-allow` (ericbaruch@gmail.com) |
| https://macmini-2018.tail2d2c60.ts.net:8445 | `tailscale serve` on the mini, then a reverse SSH tunnel to 127.0.0.1:7820 | the tailnet logins in `--allow-login` (baruchhub@gmail.com) |

Each listener trusts one identity header and ignores the other. The edge Worker deletes any `X-Gate-*` header a caller sends and sets `X-Gate-User` from the gate's own check, so the edge listener reads only that one. It serves only the `--edge-url` Host, so a request through Cloudflare can't claim a tailnet login. The main port never reads `X-Gate-User`, because `tailscale serve` passes it through untouched. The gate alone admits every full-access beric.ca account; `--edge-allow` narrows that to the owner. The 403 names the identity that arrived, which helps when a trusted-device session shows up as `tailnet:<device>` instead of an email.

The scans.beric.ca side lives in the homelab repo: the ingress rule in `services/tunnels/mac/config.yml` (`launchctl kickstart -k gui/$UID/ca.beric.beric-mac-tunnel` after an edit), the DNS route from `bun run tunnel route beric-mac scans.beric.ca`, and the offline-page label in `services/beric-gate/edge/hosts.ts`. While the Mac sleeps, the Worker answers with its "Eric's MacBook Pro is asleep or offline" page.

The tailnet route by hand: publish it with `tailscale serve` on a machine that is always on, and carry it there over a reverse SSH tunnel:

```
browser ──https──> tailscale serve on HOST :8445 ──> HOST 127.0.0.1:7820
                   ──ssh -R (scan-tunnel)──> this Mac 127.0.0.1:7820 (server.ts)
```

1. On HOST: `sudo tailscale serve --bg --https=8445 http://127.0.0.1:7820`.
2. On the Mac: `scan-catalog serve --install --public-url https://HOST.TAILNET.ts.net:8445 --allow-login you@example.com --tunnel HOST`. That writes the dashboard LaunchAgent with the two flags and a second one, `ca.beric.scan-it-tunnel`, that runs `scan-tunnel HOST` (log `~/Library/Logs/scan-it-tunnel.log`).

Requests for the public URL must carry a `Tailscale-User-Login` in the `--allow-login` list. `tailscale serve` sets that header for the signed-in tailnet user and drops any copy the client sent. Tagged nodes get none, so they are refused. The login is the real gate, since anyone who can load the page gets its token. Restrict the port in the tailnet policy as well. The server won't start with `--public-url` and no `--allow-login`. From the public URL, Show in Finder and Open scans folder are hidden and refused, because they open Finder on the Mac. `SCAN_SERVE_PUBLIC_URL` and `SCAN_SERVE_ALLOW_LOGINS` (comma-separated) are the environment equivalents.

When the Mac sleeps, HOST's sshd can keep the dead session's port bound for hours. So `scan-tunnel` frees the port before each connect, killing only a listening `sshd-session` owned by the same user. That lookup needs passwordless `sudo` on HOST. While the Mac is asleep or away, the public URL returns 502.

The static `dashboard.html` copies in Drive keep their no-network CSP. Their live block is `null`, so they show the scanner list and a link to the live page.

### Run locally and deploy

`package.json` holds the tasks. Run `bun install` once for the typecheck.

| Task | What it does |
|---|---|
| `bun run dev` | `share/server.ts --mock` on http://127.0.0.1:7830/, restarted by `bun --watch` on every save. Mock scanners, batches and jobs; the catalog is the real filing root. `dashboard.html` is read per request, so a reload shows template edits. |
| `bun run start` | `scan-catalog serve`: the real server on 7820, or the running LaunchAgent's page if it is already up. |
| `bun run typecheck` | strict `tsc` over `share/server.ts`. |
| `bun run test` | every bats suite (`bats test/`). Not `bun test`, which is bun's own runner. |
| `bun run deploy` | `scripts/deploy.sh`: typecheck and `test/serve.bats`, then `scan-catalog serve --install` with both routes and `--tunnel macmini-ts`, which restarts the server on this checkout. Then it checks the edge listener (allowed and refused), the reverse tunnel from the mini, and that scans.beric.ca answers 401 signed out. `SCAN_DEPLOY_*` variables override the URLs, logins, ports and tunnel host; `SCAN_DEPLOY_SKIP_CHECKS=1` skips the tests. |
| `bun run logs` | follow the server and tunnel logs. |

The server runs from this checkout in place, so a deploy is a restart, not a copy.

### Repo layout

```
bin/                        # the CLI tools (symlinked into ~/bin)
share/dashboard.html        # dashboard template scan-catalog renders
share/server.ts             # live dashboard server (scan-catalog serve)
scripts/deploy.sh           # bun run deploy: reinstall the LaunchAgents, check every route
package.json, tsconfig.json # task shortcuts and the strict typecheck (dev only)
docs/                       # device-options.txt (full scanimage dump), superpowers/ plans & specs
test/                       # bats suites + stubs/ (fake scanimage) + helpers/ (fake eSCL scanner, JPEG cutter): scan-batch, batch-file, checks-normalize, scan-catalog, serve, jpeg-check
ENVIRONMENT.md              # machine + scanner baseline recorded at preflight
PRD-ix500-mac-scanning.md   # original product requirements
TROUBLESHOOTING.md          # failure modes and fixes
```

## Status

In active use for document, paycheck, and mixed-batch scanning. The check workflow (scan → manifest → split → normalize → report) and the mixed-batch workflow (`scan-batch` + `batch-file`) both shipped 2026-06-11; per-check normalization inside `checks-split` and the entity registry landed 2026-06-12. Dev-only `bats` suites cover `batch-file`, `scan-batch`, `checks-normalize`, `scan-catalog` and the live server (85 tests). Run them with `bun run test`. macOS + iX500 specific; validated on the single machine recorded in `ENVIRONMENT.md`.
