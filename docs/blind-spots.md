# Blind spots

What `extract-scout` structurally cannot see, ordered by how much it mattered on the DocuSeal sweep
(2026-08-21). Defects — things the tool tries to do and gets wrong — are in
[`postmortem-docuseal-sweep.md`](postmortem-docuseal-sweep.md). This document is about things it does
not try to do.

The distinction matters because of the plugin's own rule: *"Never claim the domain is clean on data
you did not gather."* A blind spot that is **named in `not_analyzed`** is honest. A blind spot that
is **not named** silently implies coverage. Several below are in the second category.

---

## 1. Rails runtime surface — the one that decided the DocuSeal answer `[not disclaimed]`

The tool models the **constant graph**. It does not model what a model *is at runtime*. For an
extraction to another service — and overwhelmingly for an extraction to another *language* — the
runtime surface is the feasibility question, and the graph is the scheduling question.

DocuSeal's model layer is nearly acyclic (zero true cycles, 34/34). It is also, as measured directly
from `app/models/*.rb`:

| Feature | Count | Why it blocks a port |
|---|---|---|
| `encrypts` | 4 models | Rails' encryption envelope has no Node implementation. Covers API tokens and webhook secrets — credentials that cannot be silently regenerated. |
| `has_one_attached` / `has_many_attached` | 14 decls / 6 models | ActiveStorage blob tables, signed IDs, variant machinery. For a document-signing product this is the product. |
| `serialize :x, coder: JSON` | 25 decls / 13 models | JSON in **text** columns, not `jsonb`. Unqueryable by the database; both stacks must agree byte-for-byte during any dual-run. |
| `belongs_to ..., polymorphic: true` | 3 | String discriminator, no FK. **Now detected** — D2 fixed; target sets resolved across files and reported at `blocker` severity. |
| `attribute ..., default: -> {}` | 25 | App-level generation with **no DB default** — verified: `accounts.uuid` and `templates.slug` are `null: false` with no default. A Node writer violates NOT NULL. One embeds an `I18n.t` call. |
| `enum` | 5 | Integer↔symbol mapping lives in Ruby, not the schema. |

None of this appears in the report. None of it appears in `not_analyzed`. A reader who trusted the
output would have concluded "nearly acyclic, mostly leaves, go" and been wrong about the hard part.

**Recommendation.** This is a first-class seam type, not a disclaimer. `build_index.rb` already
tokenizes every model file; detecting these macros is the same work as `handle_association`. Emit a
`runtime_surface` seam listing what an extracted copy of the domain would have to reimplement, and —
minimally, today — add the category to `not_analyzed`.

---

## 2. Schema and foreign keys `[disclaimed]`

`not_analyzed` names *"schema foreign keys / column-level sharing"*, and the `boundary_assoc` seam's
`break_with` says *"Confirm the FK in schema.rb — schema analysis is out of scope here."*

The disclaimer is honest but the scope call is questionable: `db/schema.rb` is a generated, regular,
trivially parseable Ruby file sitting in the repo the tool is already walking. Parsing it would
convert "each association *almost always* implies a foreign key" into "these 14 have an FK, these 3
do not, and this one has `on_delete: :cascade` that your extracted service cannot honor." It would
also give column-level data — `null: false` with no default is exactly what surfaced blind spot #1's
last row.

The tool asks the reader to do work it is better positioned to do.

---

## 3. Transactions `[disclaimed]`

`not_analyzed` names *"transaction boundaries spanning the seam."* This is arguably the single most
common hard blocker in a real extraction: a `transaction do` block writing to models on both sides
cannot survive the split without either a distributed transaction or an accepted consistency
regression.

It is also statically detectable — a `transaction do` block whose body references constants on both
sides of the boundary is a token-level pattern, no harder than the existing DSL handlers. Named in
the honesty clause, but the honesty clause is doing work the parser could do.

---

## 4. Jobs, queues and async boundaries `[partially disclaimed]`

`not_analyzed` mentions *"runtime config: env vars, feature flags, queues, cron."* That
undersells it. Background jobs are usually a *primary* extraction seam, not config:

- `SomeJob.perform_later(record)` serializes an ActiveRecord object via GlobalID. After extraction
  the object does not exist on the other side.
- Queue names and worker pools are shared infrastructure that has to be divided.
- A job enqueued by domain A and executed against domain B is a boundary crossing that never appears
  in the constant graph as a call.

`maybe_dsl_string` catches job class *names* by accident when they appear as string literals, which
is not the same as modeling the seam.

---

## 5. Views, serializers and the frontend `[not disclaimed]`

`build_index.rb:466` globs `**/*.rb` only. Not indexed: `.erb`, `.jbuilder`, `.haml`, `.slim`,
serializer DSLs, and — for DocuSeal specifically — the Vue/Stimulus frontend that consumes these
models' JSON shape.

A model's rendered representation is part of its public contract. `Template#fields` reaching a Vue
component means the extracted service owes that JSON shape forever. The report gives no hint this
surface exists, and the `exposed_constants` / `facade_leak` metrics — which exist precisely to
measure "how leaky is the public surface" — are computed over a file set that excludes the largest
consumer of it.

---

## 6. Tests `[not disclaimed]`

`include_tests: false` by default. Defensible for coupling measurement — specs referencing a model
is not architectural coupling. But specs are typically the **largest single consumer** of a model's
API and a major share of cutover cost, and factory/fixture graphs encode cross-domain dependencies
that production code does not make explicit.

Not in `not_analyzed`. A `--with-tests` mode reported as a separate "cutover cost" figure, kept out
of the entanglement score, would answer a question teams genuinely argue about.

---

## 7. Metaprogramming and dynamic dispatch `[not disclaimed]`

Static token analysis sees `Foo::Bar`. It does not see:

- `define_method` / `method_missing` / `send` / `public_send`
- `const_get` with a computed argument (as opposed to a literal string, which `maybe_dsl_string`
  catches by shape)
- STI — `type` column dispatch, subclasses in other domains
- `ActiveSupport::Notifications` subscribe/publish pairs, which are deliberately invisible coupling
- callbacks registered across a boundary (`after_commit` in A touching B)
- `delegate_missing_to`, `ActiveSupport::Concern` `included do` blocks

DocuSeal is conventional enough that this cost little here. On a metaprogramming-heavy codebase the
tool would under-report and give no indication that it was doing so.

---

## 8. Data ownership and volume `[not disclaimed]`

The graph says `Template` and `Submission` are coupled. It does not say which side **owns the row**,
how many rows there are, or which direction the write traffic flows. "Replace traversal with an
explicit id column plus a lookup at the seam" (the `boundary_assoc` `break_with`) is very different
advice for 10k rows read-mostly versus 10M rows written on every request.

---

## 9. Temporal coupling `[disclaimed]`

*"Git co-change (temporal) coupling"* is named in `not_analyzed`. Files that always change together
are coupled regardless of what the constant graph shows, and the reverse — files that never
co-change despite a static edge — identifies edges that are safe to cut. `git log` is available in
every repo the tool runs in.

---

## 10. Same-language extraction is assumed `[not disclaimed]`

The `break_with` prose bakes in an assumption that the extracted domain stays Ruby:

- *"Vendor the concern into the domain, or promote it to an explicitly shared library"* — there is no
  shared library across a Ruby/Node boundary.
- *"Introduce `Billing::API` (or a service object) and route external callers through it"* — a
  Ruby-side facade is a useful intermediate step, but it is not the destination.
- *"Replace traversal with an explicit id column plus a lookup at the seam"* — assumes both sides can
  still reach the same database, which is often the thing being given up.

The DocuSeal question was explicitly Rails→**Node**. Nothing in the tool's output model registers
that the target language changes which advice applies. A `--target` flag, or even one line in the
report acknowledging the assumption, would prevent a reader from following advice that does not
apply to their migration.

---

## 11. Every number is printed as exact `[not disclaimed]`

`36 associations`, `18 inbound edges`, `score 4.7`. Given D1 silently drops 15.3% of association
edges, these are point estimates presented without error bars. The tool has the information to know
it is uncertain — a ref whose constant does not resolve is a *known unknown*, currently discarded by
`next unless hit` without being counted.

**Recommendation.** Count unresolved refs and surface them: *"18 references could not be resolved to
a known constant and are excluded"*. That single line converts a silent 15% error into a visible
caveat, and would have made D1 self-reporting rather than something found by hand.
