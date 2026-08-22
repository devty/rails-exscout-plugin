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

## Step 2 — Rank them in one pass

The analyzer ranks a whole candidate set itself. Do **not** run it once per domain and sort
the results by hand: that is deterministic work, it costs a model pass per candidate, and
every re-derivation is another chance to transcribe a number wrong.

```bash
printf '%s\n' $ARGUMENTS > "$CACHE/candidates.txt"
ruby "${CLAUDE_PLUGIN_ROOT}/scripts/analyze_domain.rb" \
  --index "$CACHE/index.json" --domains-from "$CACHE/candidates.txt" --summary
```

Add `--format json` when you need each domain's `metrics`, `max_severity`, `evidence` and
`seams` to write the prose. Use `--all` in place of `--domains-from` for a portfolio pass over
every namespace in the repo — or every top-level unit, in a repo that has no namespaces.

Names that resolve to no files are reported on stderr and left out of the table. Name them
explicitly in the report; never let an unresolved domain place well by default.

### When a boundary needs the resolver agent

Dispatch `rails-boundary-resolver` on the **evidence**, not on the file count. Most Rails
apps are flat, so nearly every domain resolves to one file — a file-count trigger dispatches
one agent per model against boundaries that were already exact. The `evidence` map in the
JSON records how each file was matched:

| evidence for the domain's files | reading |
|---|---|
| `pack` | a declared Packwerk boundary. No agent needed. |
| `namespace`, or `constant` + `path` | exact. No agent needed. |
| `path` only | could be a name coincidence. Dispatch. |
| `agent:*` only, or nothing resolved | dispatch, or exclude the domain and say so. |

Run whatever agents you do dispatch concurrently in one message.

## Step 3 — Read the ranking

The script orders by ascending extraction cost and puts blocking ahead of size: a blocked 2.0
goes after a clean 6.0, because a blocker is a precondition rather than a quantity. Your job
is not to re-sort that — it is to explain it, and to add the three things the table cannot
say for itself:

1. **Coupled pairs.** If two candidates cycle *with each other*, neither can go first
   independently. That pair is one extraction, not two, and it is the single most useful
   thing this command can tell a team. The table cannot see it — read the `cycles` entries
   across domains and notice when two of them name each other.
2. **Facade leakage vs raw volume.** `exposed_constants` predicts API design effort better
   than edge count does. Two domains at the same score with very different exposure are not
   the same job, and the score alone will not tell the reader that.
3. **What the number does not travel with.** The score is calibrated for ordering *within one
   repo* — see "Reading the score" in the `extract-scout` skill. Rank freely here; do not
   quote the absolute number as a portable grade.

## Step 4 — Report

Print the table the script produced. It is already ordered and already carries the
`NOT ANALYZED` clause:

```
DOMAIN                  SCORE  FILES    IN   OUT  EXPOSED  CYCLES  VERDICT
Notifications             2.1     14     9     4        3       0  Moderate
Inventory                 7.8     31    44    19       17       3  Very hard
Billing                   4.1      4     8     9        2       1  Moderate, BLOCKED
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
