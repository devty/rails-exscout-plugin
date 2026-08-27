# extract-scout

Scouts a Ruby/Rails monolith and reports how entangled a domain is — and which seams have
to break before it can be extracted.

```
/extract-scout Billing
/extract-compare Billing Inventory Notifications
```

## Who this is for

The engineer who owns the answer to *"can we pull Billing out?"* — staff, platform or
architecture — in a Rails codebase big enough that nobody holds the whole graph in their head
anymore. If your repo has a `packs/` directory, a two-year-old extraction epic, or the same
argument in planning every quarter about which domain goes first, this is pointed at you.

It is not a linter and it will not enforce an architecture on you. It measures the one you
have, cites every claim, and names what it did not look at.

## Try it in five minutes

Needs Claude Code 2.x and `ruby` on `PATH` — any Ruby >= 2.0. `Ripper` is stdlib, so there is
nothing to `gem install`, no Gemfile to touch, and nothing written into the repo you point it
at.

```bash
git clone https://github.com/devty/rails-exscout-plugin
cd rails-exscout-plugin/example
claude --plugin-dir ..
```

Then, in that session:

```
/extract-scout Billing
```

`example/` is a nineteen-file Rails app with one true cycle, one inverse association pair that
only looks like a cycle, and a two-constant facade leak. Every sample output below is real
output from it — [`example/README.md`](example/README.md) lists what is planted where, so the
claims are checkable rather than assertions.

No Claude Code handy? The analyzers are the deterministic half and they run on their own:

```bash
ruby ../scripts/build_index.rb --root . --out /tmp/index.json
```

```bash
ruby ../scripts/analyze_domain.rb --index /tmp/index.json --domain Billing
```

```bash
ruby ../scripts/analyze_domain.rb --index /tmp/index.json --summary --all
```

When you point it at your own monolith, `--plugin-dir` is still the fastest way in. To keep it
across sessions — and to arm the cross-domain hook — see [Install](#install).

## Why a plugin

Every Rails team eventually asks "can we pull Billing out?" and answers it the same way:
someone greps for a week and comes back with a feeling. The feeling is usually wrong in a
specific direction — it counts the code that mentions Billing and misses the code that
*binds* to it.

That work is a poor fit for a chat prompt and a good fit for a plugin, for three reasons:

**The mechanical part should not be re-derived.** Counting fan-in, resolving Ruby's
lexical-scope constant lookup, and separating true cycles from inverse association pairs are
deterministic. Written once as a script, they are fast, reproducible, and identical across
runs. Asked of a model each time, they are slow, expensive, and subtly different every time.

**The judgment part cannot be scripted.** Whether `TaxEngine` belongs to Billing, whether an
`includes(:invoices)` becomes an N+1 after the split, whether a cycle is a one-line injection
or a redesign — none of that is in the graph. It needs code read in context.

**Packaging is what makes the split hold.** The scripts do the counting, the agents do the
reading, and the skills enforce the discipline that matters most: every claim carries a
`file:line`, and everything the analysis did not examine gets named as unexamined. That
contract is the actual deliverable. It survives being installed in a repo none of us has
seen.

The result is a report an engineer can act on directly, and dispute directly — because the
boundary, the evidence, and the blind spots are all on the page.

If you want one of these for your own team's recurring question,
[`docs/build-your-own-plugin.md`](docs/build-your-own-plugin.md) is the five decisions that
actually mattered here, worked end to end on an example that has nothing to do with Rails.

## Everything else starts after the boundary exists

Rails has good architecture tooling and this does not replace any of it. The overlap looks
larger than it is, so it is worth being precise about where the line falls:

| | what it does |
|---|---|
| [Packwerk](https://github.com/Shopify/packwerk) | Enforces the boundaries you declared in `package.yml` |
| [packs-rails](https://github.com/rubyatscale/packs-rails) | Conventions for a monolith you have decided to split |
| [packs](https://github.com/alexevanczuk/packs) | Packwerk in Rust — same semantics, faster |
| [graphwerk](https://github.com/samuelgiles/graphwerk), [query_packwerk](https://github.com/rubyatscale/query_packwerk) | Draw and query Packwerk's own graph |

Every one of them begins **after** the boundary exists. Packwerk needs a `package.yml` to
enforce; graphwerk needs Packwerk to draw. That is the right design for what they do — a
declared boundary is better information than an inferred one, always, and once you have written
yours down Packwerk is a better tool than this one for keeping them.

`extract-scout` answers the question that comes before all of that: *which domain, and what will
it cost?* — in a repo where nobody has declared anything yet, which is the state most monoliths
are actually in and the only state in which the question is still open.

Which is why, when `packs/*/package.yml` exists, this **reads** it rather than competing with
it: the packs become the candidate domains, and pack membership is the strongest evidence a
resolution can carry. The team already wrote down the answer this tool otherwise has to infer.

## What it reports

```
DOMAIN: Billing
Resolved to 5 files of 19 indexed (77 LOC)

TARGET: extraction into a separate Ruby service

ENTANGLEMENT: 3.2/10 -- Moderate, but BLOCKED -- a seam must break before the boundary can be drawn

  Inbound   ###.......  4 edges from 3 units (3 files)
  Outbound  ####......  8 edges to 5 units
  Facade    ##........  2 domain constants referenced externally
  Cycles    ###.......  1 true cycle (+1 inverse assoc pair)
  Cohesion  ###.......  25% of edges stay inside the domain

WHAT HAS TO BREAK FIRST

  1. [BLOCKER] Cycle: Billing <-> Order
     Order calls into Billing (2 edges) and Billing calls back into Order (4 edges),
     with real behaviour on both sides. Neither can move until this is one-directional.
     Break with: Invert one direction: dependency injection, a domain event, or a
     shared interface both sides depend on.
       - app/models/order.rb:5  association  -> Billing::Invoice
       - app/models/order.rb:12  reference  -> Billing::Calculator
       - app/controllers/billing/invoices_controller.rb:5  reference  -> Order
       - app/jobs/billing/invoice_job.rb:4  reference  -> Order
```

Seams are ordered by **what blocks what**, not by size. Two hundred one-directional call
sites are tedious; one true cycle is a hard stop.

### The portfolio view

One domain at a time answers "how bad is Billing?". Ranking the whole repo answers the
question teams actually argue about, and the script does the ranking itself — no model in the
loop, reproducible run to run:

```bash
ruby scripts/analyze_domain.rb --index index.json --summary --all
```

```
DOMAIN                  SCORE  FILES    IN   OUT  EXPOSED  CYCLES  VERDICT
Fulfillment               0.1      2     0     1        0       0  Clean
Shipping                  0.4      1     1     0        1       0  Clean
Billing                   3.2      5     3     5        2       1  Moderate, BLOCKED
```

Ordered by ascending cost, with blocking ahead of size — a blocked 3.2 goes after a clean 6.0,
because a blocker is a precondition rather than a quantity. `--all` takes every namespace in
the repo, or every top-level unit in a repo that has none; `--domains-from` takes a list.

## Staying useful after the audit

An audit is a snapshot. The `PostToolUse` hook is the part that keeps the boundary honest
afterwards: when an edit **adds** an ActiveRecord association that crosses a domain
boundary, it says so immediately.

```
extract-scout: new cross-domain association

  app/models/ledger_entry.rb  (Billing -> Fulfillment)
    belongs_to :order

  This association crosses a domain boundary. It implies a join and almost
  always a foreign key -- neither survives extracting either side into its
  own service.

  If deliberate, carry on. If not, an explicit id column plus a lookup at
  the seam gives you the same data without welding the domains together.
```

**It arms only on boundaries you choose to defend.** With no boundary map the hook trusts
namespaces alone — it catches `Billing::Invoice -> Shipping::Shipment` and stays quiet
otherwise. `/extract-scout` records what it resolved into `.extract-scout/domains.json`,
including unnamespaced domains no naming convention reveals. The example above is exactly that
case: `LedgerEntry` and `Order` are both top-level constants, and nothing in their names says
they belong to different domains.

**Recording a boundary is not deciding to defend it,** and `enforce` marks the difference.
Everything the scout writes is `"enforce": false` — a measurement. The hook stays on namespace
inference until you flip an entry yourself:

```json
"Billing": { "enforce": true, "files": ["..."], "constants": ["..."] }
```

That split exists because the alternative was measured and it was bad. A per-model sweep of a
34-model app recorded 34 "domains", and treating all of them as defended made every ordinary
`belongs_to` in the app a warning — the hook's first design constraint broken by following the
skill correctly. Measurement is cheap and broad; enforcement is a decision and should be narrow.

Commit `.extract-scout/domains.json`. The boundary is a shared architectural decision, and
committing it means the hook protects the whole team rather than one laptop.

### Designed to stay quiet

A hook that cries wolf gets switched off within a day and then protects nothing. Every
ambiguous case resolves to silence:

| Situation | Behavior |
|---|---|
| Association between two `enforce: true` domains | **warns** |
| Association between domains that were only measured (`enforce: false`) | silent |
| Association within one domain (incl. Ruby lexical scope) | silent |
| Target not in any identified domain — unclassified, not foreign | silent |
| Source file belongs to no identified domain | silent |
| Association already present, file edited for another reason | silent |
| Non-Ruby file, or outside `app/ lib/ engines/ packs/ components/` | silent |
| Anything malformed, or any internal error | silent |

Turn it off entirely with `EXTRACT_SCOUT_HOOK=off`, or exclude paths via an `ignore` glob
list in `.extract-scout/domains.json`.

### Knowing it still works

Silence is the contract, which means a *broken* hook and a *quiet* one look identical: the
blanket rescue that stops an analysis bug from breaking your tools also exits 0 on a crash.
The parser is shared with `/extract-scout`, so a parser regression would degrade this hook to
a permanent no-op with no signal at all.

Two ways to check, neither of which requires noticing an absence:

```bash
ruby hooks/scripts/check_cross_domain.rb --self-test
```

Builds a throwaway two-domain repo, feeds itself a crossing association, and reports whether
the warning came out. It constructs its own payload rather than documenting a shell one-liner
— a shell mangling `\n` inside the JSON is what once produced a confident, wrong "the hook
does not fire" conclusion.

```bash
EXTRACT_SCOUT_HOOK=debug
```

Names the exit path on stderr for every invocation — `no association macro in the added text`,
`app/models/x.rb belongs to no identified domain`, or the exception and backtrace the rescue
swallowed. Off by default and silent on the hot path.

Cost, measured on macOS arm64 / Ruby 3.3 over 50 invocations each: **~53 ms** for an edit with
no association — the common case — against a **~46 ms** floor for `ruby -e ''`. The hook's own
work is the ~7 ms difference; everything else is interpreter startup, and no algorithmic change
touches it. Quote the absolute, not just the delta: if a ~50 ms `PostToolUse` hook is too much,
the lever is the process model, not the script.

An edit that does contain an association costs ~61 ms, because the parser only loads once a
macro is actually detected in the added text. It reads only the text the edit introduced, never
the repo.

## How it works

Ruby has no import statements. Zeitwerk autoloads constants by path convention, so the
dependency graph of a Rails app *is* its constant-reference graph.

1. **`scripts/build_index.rb`** lexes every `.rb` file with `Ripper` (Ruby stdlib — no gems,
   no bundler, nothing installed into your repo) and records which constants each file
   defines and references, with line numbers and edge kinds: `superclass`, `mixin`,
   `association`, `polymorphic`, `delegation`, `reference`, `polymorphic_ref`, `dsl_string`.
   It also pairs polymorphic interfaces across files — `belongs_to :record, polymorphic: true`
   in one file and `has_one :search_entry, as: :record` in another — so a polymorphic
   association resolves to the models that actually implement it.

2. **`scripts/analyze_domain.rb`** resolves the domain to a file set, walks every crossing
   edge using Ruby's real lexical-scope lookup rules, and classifies the crossings into
   ranked seams.

3. **`hooks/scripts/check_cross_domain.rb`** runs after every edit, parses only the added
   text with the same `FileAnalyzer`, and warns when a new association crosses a boundary.

4. **Agents** handle what the graph cannot: `rails-boundary-resolver` decides which files
   constitute a domain that has no namespace; `rails-seam-analyst` reads the cited call
   sites and reports whether a seam is mechanical, structural, or semantic.

### Rails-specific correctness

Naive constant-graph tools get these wrong, and each error inflates the reported coupling:

- `app/models/concerns/auditable.rb` defines `Auditable`, **not** `Concerns::Auditable` —
  Rails registers `app/*/concerns` as its own autoload root.
- A bare `Calculator` inside `module Billing` resolves to `Billing::Calculator`, not to some
  unrelated top-level `Calculator`.
- `has_many :line_items, class_name: "Billing::LineItem"` is **one** edge, not two — including
  when the macro wraps across lines, which is where the override usually lives.
- `has_many :x, through: :y` depends on *two* models: the join, which the file names, and the
  far end, which `source:` decides on the join model. Both are reported.
- `belongs_to :record, polymorphic: true` has no single target class. The name is an interface,
  not a constant; inferring `Record` from it points the edge at something that does not exist.
- `Invoice belongs_to :order` + `Order has_many :invoices` is **not a cycle**. It is one
  relationship declared from both ends — the standard Rails idiom. A true cycle needs
  behavioral edges in both directions.
- **Custom inflections are read, not guessed.** `inflect.acronym 'API'` makes
  `app/models/api_key.rb` define `APIKey`; a tool deriving `ApiKey` drops every edge touching
  it, silently. `config/initializers/inflections.rb` and `zeitwerk.rb` are parsed for
  `acronym`, `irregular`, `uncountable` and `inflector.inflect` overrides — with Ripper, so a
  commented-out rule is not a rule.
- **Packwerk packages are read, not competed with.** When `packs/*/package.yml` exists, those
  boundaries are the domains, and pack membership is recorded as the strongest evidence a
  resolution can carry. The team already wrote down the answer this tool otherwise infers.
- Constants hidden in strings (`"BillingJob".constantize`, `to: "billing/invoices#show"`)
  are real edges, reported separately because no refactoring tool will catch them for you.
  A capitalised string needs a *syntactic* reason to count, though: `default: 'UTC'` is a
  timezone, not a constant. Strings compared against a `*_type` column are the polymorphic
  discriminator and are reported with the polymorphic seam, not as generic string coupling.
- A namespace with edges in both directions is not automatically a cycle. If `Ledger::Report`
  calls in and `Ledger::Secret` gets called back, no *file* is on both sides — that is a
  `namespace_pair`, real work but not a precondition.

## Knowing where the code is going

Every remedy presumes a destination. "Promote the concern to a shared library both sides may
depend on" is good advice for a Ruby service, meaningless across a language boundary, and
beside the point inside one process. `--target` says which:

```bash
ruby scripts/analyze_domain.rb --index index.json --domain Billing --target other-language
```

| target | what changes |
|---|---|
| `ruby-service` *(default)* | extraction into a separate Ruby service |
| `modular-monolith` | one process, enforced boundaries. A cross-boundary association still works at runtime — it is a dependency to declare, not a join to sever — so it drops to `moderate`. A leaky facade becomes the main event, because the boundary *is* the product. |
| `other-language` | a rewrite. Both sides are reimplemented together, so a cycle stops being a blocker and becomes a sequencing note; the schema stops being an obstacle and becomes the specification the new data model must reproduce; shared concerns are new code to write, not code that moves. |

The most useful thing the tool can say about a cross-language port is that it is ranking the
wrong axis, so `other-language` leads with that, ahead of the ranking rather than after it:

```
! This tool ranks the static constant graph. For a cross-language rewrite that is usually
  NOT the deciding axis -- the runtime surface is, and it is not modelled here. Treat the
  ordering below as a map of the code, not as a migration plan.
```

That is not modesty. On a real Rails→Node engagement this tool ranked cycles first, and
cycles were the axis that mattered least — nothing was moving incrementally, so there was
nothing to sequence.

## What it does not analyze

Named in every report, because absence of a finding is not evidence of absence:

- schema foreign keys and column-level sharing
- transaction boundaries spanning the seam
- git co-change (temporal) coupling
- runtime config: env vars, feature flags, queues, cron

These are real seams — often the decisive ones. This build reports the static constant
graph and says so plainly rather than implying a clean bill of health.

## Install

Requires Claude Code 2.x and `ruby` on PATH. Any Ruby >= 2.0 works — `Ripper` is stdlib, so
there is nothing to `gem install` and no Gemfile to touch.

```bash
claude --version
```

If that prints 1.x, an older npm-installed `claude` is shadowing your real one on `PATH`.
`--plugin-dir` and the whole `claude plugin` subcommand only exist in 2.x.

**Load it for one session** (no install, nothing written):

```bash
claude --plugin-dir /path/to/extract-scout
```

**Install it persistently** — register the directory as a local marketplace, then install
from it. The trailing `/` matters; a bare `.` is rejected as a source:

```bash
claude plugin marketplace add ./
```

```bash
claude plugin install extract-scout@extract-scout-dev
```

Add `--scope local` to either command to keep the registration in
`.claude/settings.local.json` instead of your user config. That file records an absolute
path, so it is gitignored here rather than committed.

**Verify the components registered:**

```bash
claude plugin details extract-scout
```

Hooks load at session start, so the cross-domain warning does not arm until you restart
Claude Code. Use `claude --debug` to watch it fire.

## Layout

```
.claude-plugin/
  plugin.json                     # the plugin manifest
  marketplace.json                # local marketplace, for `claude plugin install`
skills/
  extract-scout/SKILL.md          # /extract-scout <Domain>
  extract-compare/SKILL.md        # /extract-compare <A> <B> ...
  rails-extraction-seams/SKILL.md # seam taxonomy; auto-activates in refactor talk
agents/
  rails-boundary-resolver.md      # domain -> file set, when conventions fail
  rails-seam-analyst.md           # reads call sites; mechanical vs structural vs semantic
hooks/
  hooks.json                      # PostToolUse on Edit|MultiEdit|Write
  scripts/check_cross_domain.rb   # warns on new cross-domain associations
scripts/
  build_index.rb                  # Ripper constant index
  analyze_domain.rb               # boundary walk, seam ranking, scoring
test/
  run_all.rb                      # the whole suite
  verdict_matrix.rb               # every (score, severity) headline in one table
example/                          # 19-file Rails app; the sample output above is its real output
docs/
  build-your-own-plugin.md        # the five decisions, worked on a non-Rails example
```

The hook `require`s `scripts/build_index.rb`, so it and the audit share one definition of
what an association is and cannot drift apart.

## Tests

```bash
ruby test/run_all.rb
```

No Gemfile: Minitest is a Ruby default gem, so the suite installs nothing — the same promise
the analyzers make. Each test writes its fixture repo to a temp dir and throws it away, so
there is no committed fixture to drift and no state carried between runs.

Coverage is weighted toward the places where a wrong answer looks exactly like a confident
one:

- **Token walking and inflection** — a missed edge understates coupling, a phantom edge
  overstates it, and both render identically in the report.
- **Autoload roots** — `app/*/concerns` being a root in its own right is the difference
  between `Auditable` and a constant nothing in the app references.
- **Cycles vs inverse association pairs** — the false positive called out above, asserted
  from both sides in one fixture.
- **The hook's silence matrix** — every row of that table is a test. Silence is the
  contract, not a preference.

`ruby test/verdict_matrix.rb` prints every headline the report can produce and checks that a
blocker stays legible at every magnitude.

### The check that finds what unit tests cannot

Every one of the six defects found in the DocuSeal sweep passed the whole suite, because a
unit test asserts the analyzer does what it was written to do and each defect was a shape the
fixtures did not contain. Synthetic tests cannot find the case nobody thought of.

What they leave behind is a signature: a misparse fabricates a constant, and a fabricated
constant resolves to nothing. That is measurable on any repo, with no hand-labelled ground
truth at all.

```bash
ruby scripts/analyze_domain.rb --index index.json --diagnose
```

```
RESOLUTION DIAGNOSTICS  (304 files indexed)

  KIND            TOTAL   UBIQ  RESOLVED  UNRESOLVED   RATE
  association       128      0       121           7    95%
  ...

  ok: no kind is below its resolution floor
```

Associations name models in the repo, so they should almost all resolve; the floor is 90%
rather than 100% because STI, gem-provided models and unimplemented interfaces legitimately
do not. It exits non-zero when a kind drops below its floor. On DocuSeal that number was
**84.7% while every test was green** — it is the check that would have caught the worst defect
the day it was written.

`test/corpus.rb` runs those baselines against six real Rails apps pinned in `test/corpus.json`
— DocuSeal, Mastodon, Solidus, Chatwoot, Discourse and Decidim, chosen to stress different
conventions. It clones
nothing: it reports what is missing, prints the command to fetch it, and says how many repos it
actually checked, so a skipped corpus never reads as a passing one.

| repo | shape | association resolution |
|---|---|---|
| Mastodon | 248 models, 18 custom acronyms, AMS serializers throughout | 73% → **95%** |
| Solidus | engine monorepo, seven gems each with its own `app/` | 54% → **95%** |
| Chatwoot | flat app with an `enterprise/` overlay | **97%** on first contact |
| Discourse | 44 plugins marked by `plugin.rb`, a path-dependent inflector | 85% → **97%** |
| Decidim | engine monorepo of 28 gems, heavy mixin use | **96%** on first contact |

Chatwoot is the important row: it is the one the tool was never tuned against, and it passed
without changes. The other two produced nine defects between them in an afternoon — serializer
macros counted as ActiveRecord associations, `with_options class_name:` ignored, compound
irregular plurals, `lib/` assumed autoloaded, engine monorepos resolving to *zero* roots,
inflections declared in a gem's own initializers, constant assignments not counted as
definitions, and `class ::Foo::Bar` not recognised at all.

Every one of them passed the unit suite. That is the argument for a corpus in one sentence: a
synthetic fixture can only contain the cases someone thought of.

```bash
EXTRACT_SCOUT_CORPUS=~/corpus ruby test/corpus.rb
```

## Tuning

Three places encode judgment, all deliberately isolated in `scripts/analyze_domain.rb`:

- **`SEAM_WEIGHTS`** — the ordering of what has to break first.
- **`AMBIENT_MIN_UNITS` / `AMBIENT_STRUCTURAL_PCT`** — what counts as ambient infrastructure
  rather than coupling. A constant reached widely and almost entirely by `mixin`/`superclass`
  edges is scaffolding; one reached by `reference`/`association` is a god-model and stays.
  Argued in full, including where it would be wrong, in
  [`docs/scope-decisions.md`](docs/scope-decisions.md).
- **`ASSOC_MAJOR_PER_FILE`** — crossing associations per domain file at which the volume stops
  being ordinary Rails (default 5). Below it the association seam is `moderate`, at or above it
  `major`; it is never a blocker, because volume is work rather than a precondition.
- **`Verdict.score`** — magnitude only: *how much* work, 0–10. Each component saturates so
  no single large number dominates — 400 inbound edges is a lot of mechanical work, not an
  impossibility.
- **`Verdict.verdict`** — how magnitude and blocking combine into the headline.

The score deliberately does **not** encode blocking. A domain with one true cycle can be
small, cheap and still impossible to extract, so `max_severity` carries that separately and
the headline reports both: `1.7/10 -- Clean, but BLOCKED`. Collapsing them is how an
earlier build managed to print "Clean — extractable as-is" directly above `[BLOCKER]`.

Adjust these to match how your team actually sequences migration work.

## License

MIT. See [`LICENSE`](LICENSE).
