---
name: extract-scout
description: Scouts a Ruby/Rails monolith to report how entangled a named domain is and which seams must break before it can be extracted. Use when the user runs /extract-scout, or asks whether a domain like Billing, Payments or Inventory can be pulled out of the monolith, what is blocking an extraction, how coupled a module is, or where to start breaking up a Rails app.
argument-hint: <DomainName> [--refresh] [--out PATH]
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent
---

# Extract Scout

Report how entangled one domain is inside a Rails monolith, and what must break first
before it can be extracted.

The value of this report is **specific, cited seams** — not a score. An engineer will not
act on "Billing is 6/10 coupled." They act on
`app/models/billing/invoice.rb:12 calls LedgerEntry.create! while LedgerEntry belongs_to Invoice`.
Every claim must carry a `file:line`.

## Inputs

`$1` is the domain name, capitalized as it would appear in code (`Billing`, `Payments`,
`Inventory`). If no argument was given, ask which domain — do not guess.

Flags: `--refresh` forces a rebuild of the index cache; `--out PATH` overrides the report
destination.

## Step 1 — Preflight

Confirm this is a Ruby/Rails repo and Ruby is available:

```bash
ruby -v && ls Gemfile config/application.rb 2>/dev/null
```

- No `ruby` on PATH → stop and say so. The analyzers are Ruby scripts using only stdlib.
- No `Gemfile`/`config/application.rb` → this may be plain Ruby rather than Rails. Continue,
  but note in the report that Rails autoload conventions may not apply, which weakens
  path-based domain resolution.

## Step 2 — Build or reuse the constant index

Cache to `tmp/` when it exists (Rails gitignores it), otherwise the system temp dir:

```bash
CACHE="tmp/extract-scout"; [ -d tmp ] || CACHE="${TMPDIR:-/tmp}/extract-scout"
mkdir -p "$CACHE"
ruby "${CLAUDE_PLUGIN_ROOT}/scripts/build_index.rb" --root . --out "$CACHE/index.json"
```

Reuse an existing `index.json` if it is newer than the most recently modified `.rb` file
and `--refresh` was not passed. On a large monolith the index takes a few seconds; say so
rather than sitting silent.

Read the `stats` block from the output. If `files_indexed` is under 20, the excludes are
probably wrong for this repo — check `autoload_roots` before continuing.

## Step 3 — Resolve the domain to a file set

```bash
ruby "${CLAUDE_PLUGIN_ROOT}/scripts/analyze_domain.rb" \
  --index "$CACHE/index.json" --domain "$1" --format json
```

The script resolves mechanically: namespace match, constant-prefix match, path-segment
match. That is sufficient for a namespaced domain (`app/models/billing/**`).

**It is not sufficient for the common case where a domain is conceptual rather than
namespaced** — where `Invoice`, `LedgerEntry` and `Receipt` are all Billing but none is
under a `Billing::` namespace. Dispatch the `rails-boundary-resolver` agent when any of
these hold:

- the script exits with "matched no files"
- fewer than 3 files resolved
- `evidence` shows only `path` matches (name coincidence, not structure)
- the user named a business concept with no matching namespace

Pass the agent the domain name and the index path. It returns constants and files to feed
back as `--extra-const` / `--extra-file`, then re-run the analysis. Report what the agent
added and why, so the reader can dispute the boundary — a wrong boundary invalidates every
number that follows.

## Step 4 — Ground the top seams in real code

The script reports graph structure. It does not know what the code *means*. For the top 3
seams, dispatch the `rails-seam-analyst` agent with those citations to read the actual call
sites and report what breaking each seam concretely requires.

Skip this only when the domain resolves to fewer than ~5 files and the seam list is short
enough to read directly. In that case read the cited files yourself with Read.

## Step 5 — Write the report

Write markdown to `--out` if given, else `extract-scout-<domain-lowercase>.md` in the repo
root. Structure:

1. **Verdict** — score, label, and one sentence a tech lead could repeat in a planning meeting.
2. **Boundary** — which files are in the domain and *how each was determined*. Flag any file
   included on agent judgment rather than structure.
3. **Seams, ordered** — for each: what it is, why it blocks, how to break it, and the
   citations. Preserve the script's ordering; it ranks by what-blocks-what, not size.
4. **Inbound / outbound tables** — the units on each side, with edge counts.
5. **Not analyzed** — copy the script's `not_analyzed` list verbatim. This is the report's
   honesty clause. Never drop it.

Then print the terminal summary (`--format text`) so the user sees the result immediately,
and give the report path.

## Step 6 — Persist the boundary map

Record the resolved boundary to `.extract-scout/domains.json`.

**Measuring a boundary is not the same as deciding to defend it.** This file holds both, and
`enforce` is what separates them. Write `"enforce": false` for anything resolved as part of an
audit. Only a deliberate architectural decision — someone saying *"this boundary is real and I
want it protected"* — flips it to `true`.

That distinction is load-bearing. The `PostToolUse` hook arms only on enforced domains. A sweep
that records every model as its own domain and marks them all enforced turns every ordinary
`belongs_to` into a warning, and a hook that cries wolf gets switched off within a day and then
protects nothing. Unenforced entries leave the hook on its conservative namespace-inference
fallback, which is the near-zero-false-positive case.

**Merge, never overwrite.** Scouting `Payments` must not erase the `Billing` entry recorded
last week.

```json
{
  "version": 1,
  "domains": {
    "Billing": {
      "enforce": false,
      "confidence": "medium",
      "scouted": "2026-08-20",
      "files": ["app/models/billing/invoice.rb", "app/models/ledger_entry.rb"],
      "constants": ["Billing::Invoice", "LedgerEntry"]
    }
  },
  "ignore": []
}
```

Read any existing file first, replace only this domain's key, and write the merged result.
**Never downgrade an existing `"enforce": true` to `false`** — that is a decision the user made,
and re-scouting a domain must not silently disarm the boundary they chose to protect.

Carry `confidence` through from the boundary resolver — a `low`-confidence boundary produces
low-confidence hook warnings, and the reader deserves to know which they are.

Tell the user the file was written, that it is worth committing, and that the hook stays quiet
until they set `"enforce": true` on the boundaries they actually want defended. If this write
adds more than a handful of domains at once, say so explicitly — that is a measurement sweep,
not an architecture decision, and enforcing all of it would be a mistake.

## Rules

- **Never invent a citation.** Every `file:line` must come from script output or a file you
  actually read. A fabricated line number destroys trust in the whole report.
- **Never claim the domain is clean on data you did not gather.** Foreign keys, transactions,
  git history and runtime config are outside this analysis. Say "not analyzed", never "none found".
- **Do not soften a blocker.** If a true cycle exists, it is a blocker even when the user
  hopes otherwise.
- **Report low confidence when the boundary is uncertain.** A resolved boundary built mostly
  from agent judgment deserves an explicit caveat at the top, not a footnote.
- Association-pair bidirectionality is *not* a cycle. The script already separates these;
  do not re-promote inverse pairs to blockers when writing prose.

## Reference

`references/report-template.md` — the full report skeleton with an example.
