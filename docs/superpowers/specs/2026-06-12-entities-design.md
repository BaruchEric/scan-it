# Entities — per-entity document attribution and filing

**Date:** 2026-06-12
**Status:** Implemented
**Repo:** ~/Arik/dev/office/scan-it
**Extends:** 2026-06-11-scan-batch-design.md

## Problem

Filed documents (taxes, contracts, expense receipts, statements) belong to
different legal entities — the user personally, or one of his businesses — and
accountants need them separable per entity. The batch pipeline filed only by
document type, with no entity dimension.

## Design

### Entity registry — `~/Documents/Scans/entities.json`

User data, lives in the filing root (`batch-file`'s `--outdir`), not the repo:

```json
{
  "entities": [
    { "slug": "personal",       "name": "Personal",           "kind": "personal" },
    { "slug": "rio-laundromat", "name": "RIO LAUNDROMAT LLC", "kind": "business" },
    { "slug": "rio-cycles",     "name": "RIO CYCLES LLC",     "kind": "business" },
    { "slug": "aqualoop",       "name": "AQUALOOP LLC",       "kind": "business" }
  ]
}
```

Adding an entity = adding a line here. `slug` is the canonical id used in
manifests, folders, sidecars, and the index; `name` is the legal/display name.

### Manifest: optional `entity` per document

```json
{ "type": "tax", "name": "tax-2026-04-15-1099-misc", "entity": "rio-cycles", ... }
```

Validation (batch-file, fail-closed — nothing written on violation):

- `entity` must match `^[a-z0-9][a-z0-9-]*$` (no path separators).
- When `<outdir>/entities.json` exists, the slug must be listed in it
  ("unknown entity: <slug>"). Without a registry, the slug-format check alone
  applies (keeps the tool usable on other filing roots).

### Filing

- Entity documents land in `<type-folder>/<entity>/<name>.pdf`
  (e.g. `taxes/rio-laundromat/`, `receipts/personal/`).
- Entity-less documents land at the type-folder root, exactly as before
  (fully backward compatible).
- Sidecar `.json` and `index.jsonl` lines carry `entity` (null when absent),
  so per-entity queries work even across the un-foldered legacy documents.
- Paychecks ignore entity — they keep routing through checks-split into
  `paychecks/checksYYYYMMDD.pdf`.

### New document type: `tax`

`tax` → `taxes/` folder; fields like contract/statement/letter (party, date,
title). Covers returns, W-2/1099s, property-tax bills, IRS/state notices.

### Claude analysis (scan skill)

During per-sheet analysis Claude reads the registry, matches the entity name
printed on the document (LLC name on invoices, contracts, tax forms), and
records the slug. Unclear entity → leave it off and flag at bucket review;
never guess. The bucket summary line shows the entity in brackets.

## Tests

`test/batch-file.bats`: per-entity subfolder filing + sidecar/index fields;
entity-less root filing with registry present; unknown entity rejected
(exit 1, nothing written); bad slug rejected without registry; entity accepted
without registry; `tax` type files into `taxes/`.
