# Report template

Skeleton for the markdown `/extract-scout` writes. Adapt section contents; keep the section
order and keep "Not analyzed" — it is the report's honesty clause.

---

# Extraction scout: {Domain}

**Verdict: {score}/10 — {label}**

{One sentence a tech lead can repeat in a planning meeting. Name the single biggest
obstacle, not a summary of everything.}

Generated {date} against {commit-sha}. Static constant-reference analysis only — see
"Not analyzed".

## Boundary

{N} files, {LOC} lines resolved as {Domain}.

| File | LOC | How resolved |
|---|---|---|
| `app/models/billing/invoice.rb` | 38 | namespace |
| `app/models/ledger_entry.rb` | 12 | agent judgment — written only by Invoice#finalize! |

{If any file was included on agent judgment rather than structure, say so here and state the
confidence. A wrong boundary invalidates every number below it — the reader must be able to
dispute it.}

## What has to break first

Ordered by precondition, not by size. Each seam is listed with what it is, why it blocks,
and how it is broken.

### 1. {BLOCKER} {Seam title}

{Why this blocks the extraction, in two sentences.}

**Break with:** {Concrete approach.}

| Site | Kind | Target |
|---|---|---|
| `app/models/order.rb:6` | reference | `Billing::Calculator` |

{If the seam-analyst read these sites, add its assessment: mechanical / structural /
semantic, the effort estimate, and any second-order breakage such as `includes` that becomes
an N+1.}

### 2. {MAJOR} ...

## Coupling detail

**Inbound** — becomes your API surface.

| Unit | Edges | Files | Kinds |
|---|---|---|---|
| Order | 3 | 1 | association 1, reference 2 |

**Outbound** — becomes your dependencies.

| Unit | Edges | Kinds |
|---|---|---|
| Account | 1 | association 1 |

**Exposed constants** — {N} domain constants referenced from outside. {List them. Above ~8,
note that a facade is required before anything else.}

## Not analyzed

Absence of a finding below is **not** evidence of absence:

- schema foreign keys / column-level sharing
- transaction boundaries spanning the seam
- git co-change (temporal) coupling
- runtime config: env vars, feature flags, queues, cron

{If any is likely to matter for this domain, say which and why.}

## Suggested sequence

1. {First concrete step, with the file it touches.}
2. ...

{Order by precondition. Converting string references usually comes first regardless of rank
— it makes every later step fail at boot rather than in production.}
