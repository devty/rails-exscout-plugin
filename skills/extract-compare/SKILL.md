---
name: extract-compare
description: Ranks several candidate domains in a Ruby/Rails monolith by how expensive each would be to extract, so a team can pick which to pull out first. Use when the user runs /extract-compare, or asks which domain or service to extract first, which module is the easiest or cheapest to split out, how two domains compare in coupling, or where to start decomposing a monolith.
argument-hint: <Domain1> <Domain2> [Domain3 ...]
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent
---

# Extract Compare

Rank candidate domains by extraction cost so a team can sequence the work.

`/extract-scout` answers "how bad is Billing?". This answers the question teams actually
argue about in planning: **"which one do we do first?"**

## Inputs

`$ARGUMENTS` is two or more domain names. With fewer than two, ask for the rest — a
comparison of one thing is just `/extract-scout`, so redirect there instead.

## Step 1 — Index once, reuse for every domain

Build the index a single time. It is domain-independent, and rebuilding per domain wastes
seconds per candidate on a large repo.

```bash
CACHE="tmp/extract-scout"; [ -d tmp ] || CACHE="${TMPDIR:-/tmp}/extract-scout"
mkdir -p "$CACHE"
ruby "${CLAUDE_PLUGIN_ROOT}/scripts/build_index.rb" --root . --out "$CACHE/index.json"
```

## Step 2 — Analyze each domain

For each name, run the analyzer in JSON mode and keep the `metrics`, `entanglement_score`,
`max_severity` and `seams`:

```bash
ruby "${CLAUDE_PLUGIN_ROOT}/scripts/analyze_domain.rb" \
  --index "$CACHE/index.json" --domain "$NAME" --format json
```

Domains resolving to fewer than 3 files need the `rails-boundary-resolver` agent before
their numbers mean anything. When comparing, dispatch the agent for **every** weakly
resolved domain, not just some — an unresolved domain looks artificially clean, and that
asymmetry silently corrupts the ranking. Run these agents concurrently in one message.

If a domain cannot be resolved at all, exclude it from the ranking and say so explicitly.
Never let it place well by default.

## Step 3 — Rank

Order by ascending extraction cost, weighing in this order:

1. **Blocking** (`max_severity == "blocker"`) — a domain with any genuine cycle ranks below
   one with none, regardless of size. A cycle is preparatory work you cannot skip, and
   `entanglement_score` deliberately does not encode it: rank on `max_severity` first, then
   on score. A blocked 2.0 goes after a clean 6.0.
2. **Facade leakage** (`exposed_constants`) — how many internals outsiders touch. This
   predicts API design effort better than raw edge count.
3. **Inbound units** — how many callers need a client on cutover day.
4. **Boundary associations** — data-layer work, usually the long pole.
5. **Size** (`domain_files`, `domain_loc`) — as a tiebreak only. Small and tangled is worse
   than large and clean.

Cross-domain check worth surfacing: if two candidates cycle *with each other*, neither can
go first independently. Say so — that pair is one extraction, not two, and it is the single
most useful thing this command can tell a team.

## Step 4 — Report

Print a comparison table:

```
DOMAIN       SCORE  FILES  IN   OUT  EXPOSED  CYCLES  VERDICT
Notifications  2.1     14    9     4        3       0  Moderate
Billing        4.1      4     8     9        2       1  Moderate, BLOCKED
Inventory      7.8     31    44   19       17       3  Very hard, BLOCKED
```

Then, in prose:

- **Start here** — the recommended first extraction and the reason in one sentence.
- **Why not the others** — one line each. Be specific: "Inventory has 3 cycles, one with
  Orders" beats "Inventory is more coupled".
- **Coupled pairs** — any domains that cycle with each other and must move together.
- **Not analyzed** — the same honesty clause `/extract-scout` carries. Ranking on partial
  signal is still ranking on partial signal.

Write the table plus prose to `extract-compare-report.md` and print the table to terminal.

## Step 5 — Persist every resolved boundary

A comparison resolves several domains in one pass, which is the cheapest moment to record
them all. Merge each into `.extract-scout/domains.json` using the schema in the
`extract-scout` skill, preserving domains already recorded there.

Write every one of them with `"enforce": false`. A comparison is a measurement — the whole
point is that the team has not yet decided which domain to extract, so none of these
boundaries is a decision anyone has made. The `PostToolUse` hook arms only on enforced
domains, and enforcing a whole comparison set would warn on ordinary associations across
most of the app.

Once the team picks a domain and commits to the boundary, they flip that one entry to
`"enforce": true` and the hook starts defending it. Say so when you report the file was
written.

Skip any domain that failed to resolve. A wrong boundary in this file produces wrong
warnings on every future edit, which is worse than no boundary at all.

## Rules

- **Compare like with like.** If one domain got agent-assisted boundary resolution and
  another did not, say so — the numbers are not directly comparable.
- **Never recommend a domain you could not resolve.**
- A low score means *cheaper to extract*, not *more valuable to extract*. Business value is
  the user's call; state that explicitly so the ranking is not mistaken for a roadmap.
