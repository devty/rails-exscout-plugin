# Scope decisions

Choices about **what this tool refuses to analyze**, and the arguments for them.

These are separate from [`blind-spots.md`](blind-spots.md), which records what the tool cannot
see, and from [`open-questions.md`](open-questions.md), which records what is unresolved. A scope
decision is deliberate: we looked at something, decided it was not ours to report, and can be
argued out of it. Each entry states the rule, the evidence, and — most importantly — **the case
where it would be wrong**.

---

## 1. Ambient infrastructure is not coupling

**Rule.** A constant reached by at least 10 distinct top-level units, whose edges are at least
90% `mixin` or `superclass`, is set aside before any counting. It is reported under `AMBIENT` in
the domain report and excluded from seams, metrics and the score.

### The argument

A concern included by 52 of an app's units is not a dependency that domain chose. It is ambient —
present everywhere, informative nowhere. Reporting it as a seam surfaces it in *every* domain's
report simultaneously, which is noise everywhere at once, and the remedy the tool attaches to it
("promote it to an explicitly shared library both sides may depend on") is unactionable, because
it already is one.

This is the same principle the analyzer applies twice already, extended one step:

| mechanism | how it decides | maintained by |
|---|---|---|
| constant resolution | "not defined in this repo" → gem or framework | nothing; true by construction |
| `DEFAULT_UBIQUITOUS` | a hardcoded list of 11 base classes | a human, and it rots |
| **ambient detection** | "reached by much of the app, structurally" | **measurement** |

The third subsumes the second. On Mastodon it identifies `ApplicationRecord`,
`ApplicationController` and `ApplicationPolicy` without being told, and it also catches
`BaseService` (68 units) — which the hardcoded list does not contain and never would have, because
nobody thought of it.

### Why breadth alone is not the rule, and why that matters

The first version of this used fan-in breadth only. It set aside `Account`.

`Account` is reached by 171 units, the widest reach in Mastodon — and it is the god-model, the
single most important coupling fact in the application. A breadth-only rule deletes the headline
and calls it noise.

Edge kind separates them, and on real code the split is bimodal with nothing in the middle:

| infrastructure | units | structural | | domain model | units | structural |
|---|---|---|---|---|---|---|
| `ApplicationRecord` | 132 | **93%** | | `Account` | 171 | **0%** |
| `BaseService` | 68 | **100%** | | `Status` | 77 | **0%** |
| `Redisable` | 52 | **100%** | | `User` | 37 | **0%** |
| `RoutingHelper` | 26 | **100%** | | `Tag` | 25 | **0%** |

A `superclass` or `mixin` edge says *"this constant is scaffolding I am built on."* A `reference`
or `association` edge says *"this constant is a thing I use."* Only the second is coupling that
extraction has to resolve.

### Where this would be wrong

Argue with it here first:

- ~~**A shared concern that carries real domain behaviour.**~~ **Fixed — see "Ambience is
  relative to the domain" below.** This was the first case listed here, and looking for a repo
  that exhibited it found one immediately, in a corpus repo already checked in.

### Ambience is relative to the domain

Ambience is measured across the whole app, but a report is about **one domain**, and the two can
disagree.

Mastodon's `JsonLdHelper` clears the global rule easily — 12 units, 100% structural — so the
first version of this set it aside from every report. But **35 of its 46 includes (76%) are
inside ActivityPub**, and it is 379 lines of `canonicalize`, `compact`, `patch_for_forwarding!`,
`safe_for_forwarding?`, `fetch_resource` and `collection_items`. ActivityPub *is* JSON-LD. That
is the protocol implementation, factored into a helper — not scaffolding, and anyone extracting
ActivityPub takes all 379 lines with them.

A domain contributes many **edges** but only one **unit**, so the global measure and the local
one pull apart exactly here. The refinement: a globally-ambient constant is **reinstated** as
real coupling for a domain when at least 60% of its structural edges originate inside that
domain's own file set.

| module | structural edges | inside ActivityPub | |
|---|---|---|---|
| `JsonLdHelper` | 46 | **35 (76%)** | **reinstated** |
| `RoutingHelper` | 61 | 18 (30%) | stays ambient |
| `Payloadable` | 33 | 7 (21%) | stays ambient |
| `Redisable` | 64 | 6 (9%) | stays ambient |

The separation is clean again — 76% against a 9–30% cluster — which is some evidence the
threshold is not balanced on a knife edge.

Ambience is therefore a property of the **pair**, not of the constant. `JsonLdHelper` is
reinstated for ActivityPub and still set aside for `Web`, which merely uses it. Both readings
are correct, and the report says which one it applied and why.

### Changing it

`AMBIENT_MIN_UNITS`, `AMBIENT_STRUCTURAL_PCT`, `AMBIENT_MEASURABLE_MIN` and `STRUCTURAL_KINDS` in
`scripts/build_index.rb`. Every domain report prints what it set aside and the numbers that
justified it, so a reader can disagree with a specific call rather than with the idea.

---

## 2. Seams are ordered by severity tier, then by size

**Rule.** `Analyzer.order_seams` sorts on `[severity, score]`, not on `score` alone.

The README has always promised *"Seams are ordered by what blocks what, not by size."* Ordering on
score alone did not deliver it. Seam scores have no saturation, so on Mastodon's `ActivityPub`
the `shared_mixin` seam scored `35 + 98×2 = 231` and outranked a genuine cycle at `100 + 35 =
135` — **one moderate seam ranked above twenty-six blockers**, in a report whose entire thesis is
that blockers come first.

Severity *is* what-blocks-what, so it is the primary key. Score orders within a tier, where it
means "how much of this kind of work", which is the question it can actually answer.

### Where this would be wrong

A seam's severity is itself computed, and a wrong severity is now unrecoverable by volume: a
`moderate` seam with ten thousand citations still sorts below a `blocker` with one. That is the
intended behaviour and it does put all the weight on severity being right. Severities are assigned
in `rank_seams` and, per target, in `Targets::SPECS`.
