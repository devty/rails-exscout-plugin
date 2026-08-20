# extract-scout

Scouts a Ruby/Rails monolith and reports how entangled a domain is — and which seams have
to break before it can be extracted.

```
/extract-scout Billing
/extract-compare Billing Inventory Notifications
```

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

## What it reports

```
DOMAIN: Billing
Resolved to 4 files (41 LOC)

ENTANGLEMENT: 4.1/10 -- Moderate, but BLOCKED -- a seam must break before the boundary can be drawn

  Inbound   #####.....  8 edges from 5 units (5 files)
  Outbound  #######...  9 edges to 8 units
  Facade    ##........  2 domain constants referenced externally
  Cycles    ###.......  1 true cycle (+3 inverse assoc pairs)
  Cohesion  ##........  15% of edges stay inside the domain

WHAT HAS TO BREAK FIRST

  1. [BLOCKER] Cycle: Billing <-> Order
     Order calls into Billing (3 edges) and Billing calls back into Order (2 edges),
     with real behaviour on both sides. Neither can move until this is one-directional.
     Break with: Invert one direction: dependency injection, a domain event, or a
     shared interface both sides depend on.
       - app/models/order.rb:6  reference  -> Billing::Calculator
       - app/controllers/billing/invoices_controller.rb:5  reference  -> Order
```

Seams are ordered by **what blocks what**, not by size. Two hundred one-directional call
sites are tedious; one true cycle is a hard stop.

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

**It gets smarter after you run the audit.** With no boundary map, the hook can only trust
namespaces — it catches `Billing::Invoice -> Shipping::Shipment` and stays quiet otherwise.
Once `/extract-scout` writes `.extract-scout/domains.json`, the hook inherits the boundary
the resolver worked out, including unnamespaced domains no naming convention reveals. The
example above is exactly that case: `LedgerEntry` and `Order` are both top-level constants,
and nothing in their names says they belong to different domains.

Commit `.extract-scout/domains.json`. The boundary is a shared architectural decision, and
committing it means the hook protects the whole team rather than one laptop.

### Designed to stay quiet

A hook that cries wolf gets switched off within a day and then protects nothing. Every
ambiguous case resolves to silence:

| Situation | Behavior |
|---|---|
| Association between two identified domains | **warns** |
| Association within one domain (incl. Ruby lexical scope) | silent |
| Target not in any identified domain — unclassified, not foreign | silent |
| Source file belongs to no identified domain | silent |
| Association already present, file edited for another reason | silent |
| Non-Ruby file, or outside `app/ lib/ engines/ packs/ components/` | silent |
| Anything malformed, or any internal error | silent |

Turn it off entirely with `EXTRACT_SCOUT_HOOK=off`, or exclude paths via an `ignore` glob
list in `.extract-scout/domains.json`.

Cost is roughly 6ms over Ruby interpreter startup for an edit with no association — the
common case — because the parser only loads once a macro is actually detected in the added
text. It reads only the text the edit introduced, never the repo.

## How it works

Ruby has no import statements. Zeitwerk autoloads constants by path convention, so the
dependency graph of a Rails app *is* its constant-reference graph.

1. **`scripts/build_index.rb`** lexes every `.rb` file with `Ripper` (Ruby stdlib — no gems,
   no bundler, nothing installed into your repo) and records which constants each file
   defines and references, with line numbers and edge kinds: `superclass`, `mixin`,
   `association`, `delegation`, `dsl_string`, `reference`.

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
- `has_many :line_items, class_name: "Billing::LineItem"` is **one** edge, not two.
- `Invoice belongs_to :order` + `Order has_many :invoices` is **not a cycle**. It is one
  relationship declared from both ends — the standard Rails idiom. A true cycle needs
  behavioral edges in both directions.
- Constants hidden in strings (`"BillingJob".constantize`, `to: "billing/invoices#show"`)
  are real edges, reported separately because no refactoring tool will catch them for you.

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

## Tuning

Three places encode judgment, all deliberately isolated in `scripts/analyze_domain.rb`:

- **`SEAM_WEIGHTS`** — the ordering of what has to break first.
- **`Verdict.score`** — magnitude only: *how much* work, 0–10. Each component saturates so
  no single large number dominates — 400 inbound edges is a lot of mechanical work, not an
  impossibility.
- **`Verdict.verdict`** — how magnitude and blocking combine into the headline.

The score deliberately does **not** encode blocking. A domain with one true cycle can be
small, cheap and still impossible to extract, so `max_severity` carries that separately and
the headline reports both: `1.7/10 -- Clean, but BLOCKED`. Collapsing them is how an
earlier build managed to print "Clean — extractable as-is" directly above `[BLOCKER]`.

Adjust these to match how your team actually sequences migration work.
