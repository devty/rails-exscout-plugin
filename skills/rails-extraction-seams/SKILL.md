---
name: rails-extraction-seams
description: Knowledge of how coupling seams in Ruby on Rails monoliths are broken before a domain can be extracted into a service or engine - dependency cycles, missing facades, cross-boundary ActiveRecord associations, string-based constant references, and shared concerns. Use when discussing splitting up a Rails monolith, extracting a domain or bounded context, breaking a dependency cycle between Rails models, replacing an association that crosses a service boundary, or sequencing a decomposition effort.
---

# Rails Extraction Seams

How each kind of coupling in a Rails monolith is actually broken. Use when advising on
decomposition, and when interpreting `/extract-scout` output into concrete work.

## The ordering principle

Seams are not ranked by size. They are ranked by **what blocks what**.

A domain with 200 one-directional call sites is mechanical work — tedious, parallelizable,
low risk. A domain with 12 call sites and one true cycle is blocked: you cannot even draw
the boundary until the cycle is inverted. Always sequence by precondition, then by volume.

## Seam types, hardest first

### 1. True dependency cycle — blocker

`Billing` calls `Order` methods and `Order` calls `Billing` methods. Neither side can move
first.

**Not a cycle:** `Invoice belongs_to :order` paired with `Order has_many :invoices`. That is
one relationship declared from both ends, the standard Rails idiom. Treating inverse
association pairs as cycles produces false blockers and destroys confidence in the analysis.

A cycle is genuine when **both** directions carry behavioral edges — method calls, mixins,
inheritance — not merely association macros.

**Breaking it**, cheapest first:

- **Invert with an event.** The lower-level side publishes; the higher-level side subscribes.
  `Order` emits `order.completed`; Billing listens. Removes the edge entirely rather than
  hiding it. Rails-native options: ActiveSupport::Notifications for in-process, an outbox
  table for anything that must survive a crash.
- **Inject the dependency.** `Billing::Calculator.new(rate_source: Shipping::RateTable)`
  instead of referencing the constant inline. Cheap, keeps behavior identical, but the
  coupling survives at the composition root — a staging post, not a destination.
- **Extract a shared interface** both sides depend on. Correct when the shared concept is
  genuinely shared. Overkill when only one direction is real.

Sequence note: invert the direction that has fewer call sites, unless one direction is
clearly the domain-model-correct one — billing depending on orders is usually right;
orders depending on billing usually is not.

### 2. Missing facade — blocker at scale

External code references many domain internals rather than one entry point. Each referenced
constant becomes a public API method or a breaking change.

**Breaking it:** introduce `Billing::API` (a plain module of module-functions is enough — no
framework required) and migrate callers one constant at a time. Ship the facade first while
internals stay reachable, migrate incrementally, then make internals private. The facade is
not overhead; it is the thing that lets the extraction land in pieces instead of one
irreversible PR.

Rule of thumb: more than ~8 externally-referenced constants means design the facade before
touching anything else.

### 3. Cross-boundary ActiveRecord association — major

`belongs_to`/`has_many` crossing the seam. Implies a join and almost always a foreign key.
After extraction the join cannot happen in SQL.

**Breaking it:**

- Replace traversal with an explicit id column plus an explicit lookup: `invoice.order_id`
  and a call at the seam, never `invoice.order.customer.name`.
- Hunt `includes`/`joins`/`preload` naming the association — those become N+1s or errors the
  moment the tables separate. This is the most common way an extraction ships and then melts
  under production load.
- Denormalize the one or two fields actually read across the boundary. Copying
  `customer_name` onto invoices is not a design failure; it is what a service boundary costs.
- Drop the FK constraint deliberately and early, in its own migration, so the failure surface
  appears while everything is still one deployable.

Order matters: id column → migrate reads → drop the association macro → drop the FK.

### 4. String-based constant reference — major, and silent

`"BillingJob".constantize`, `to: "billing/invoices#show"`, Sidekiq class names in YAML,
`class_name:` strings. Invisible to every refactoring tool, every static check, and to
`rg BillingJob` if the string is built by interpolation.

**Breaking it:** convert to real constant references *before* moving any code. Then the rest
of the extraction fails at boot instead of at 3am. This is nearly always the cheapest seam
to fix and it should usually be done first regardless of rank, because it makes every
later step fail loudly.

### 5. Shared concern or mixin — moderate

The domain includes a module defined outside it. On extraction the concern either travels
(duplicated logic, drifting copies) or stays (a new shared dependency).

**Breaking it:** decide whether the concern is *domain logic* or *infrastructure*.
Infrastructure (`Auditable`, `Timestampable`) belongs in a shared library both sides depend
on. Domain logic that happens to be reused is usually two different behaviors that were
merged prematurely — vendor a copy into the domain and let them diverge honestly.

### 6. Inbound call volume — moderate

Many one-directional call sites. Does not block the split; every site still needs a
client-side replacement on cutover day.

**Breaking it:** route callers through a single client/adapter first, while everything is
still in-process. Cutover then changes one file instead of forty.

## What static analysis cannot see

Say these are unexamined rather than implying they are clean:

- **Shared tables and columns** — two domains writing the same row is a harder blocker than
  any code edge, and no constant graph reveals it.
- **Transactions spanning the seam** — a single `transaction do` touching both sides means
  extraction requires giving up atomicity. Usually the true long pole.
- **Temporal coupling** — files that always change together despite sharing no references.
  An invisible contract living in developers' heads.
- **Runtime config** — shared env vars, feature flags, queues, cron. The coupling that only
  bites after the extraction ships.

## Advising sequence

1. Convert string references to constants — makes everything after fail loudly.
2. Break true cycles — until done, the boundary does not exist.
3. Build the facade — lets the rest land incrementally.
4. Migrate associations to ids — the long pole; start early, run parallel to 3.
5. Route bulk callers through the client.
6. Split the data.
7. Move the code — by this point, the smallest step.

Most failed extractions attempt step 7 first.
