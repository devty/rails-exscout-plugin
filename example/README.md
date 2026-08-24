# example/

A nineteen-file Rails app that exists so the sample output in the
[top-level README](../README.md) is something you can **reproduce** rather than take on faith.

```bash
claude --plugin-dir ..
```

```
/extract-scout Billing
```

Or without Claude Code, straight against the analyzers:

```bash
ruby ../scripts/build_index.rb --root . --out /tmp/index.json
```

```bash
ruby ../scripts/analyze_domain.rb --index /tmp/index.json --domain Billing
```

There is no database, no `bundle install`, and nothing to boot. `extract-scout` reads source
text — the app only has to be *shaped* like Rails, not runnable.

## What is deliberately planted in here

Each of these is a claim the top-level README makes, made checkable:

| File | What it demonstrates |
|---|---|
| `app/models/order.rb` + `app/controllers/billing/invoices_controller.rb` | A **true cycle**. Behavioural edges in both directions, so neither side moves until one is inverted. This is the `[BLOCKER]`. |
| `app/models/payment.rb` + `app/models/billing/invoice.rb` | An **inverse association pair**, which is *not* a cycle. `belongs_to` on one side and `has_many` on the other is one relationship declared from both ends. A tool that counts it as bidirectional coupling reports a blocker in an app that has none. |
| `app/models/concerns/auditable.rb` | The `app/*/concerns` **autoload root**. This file defines `Auditable`, not `Concerns::Auditable`. |
| `app/models/billing/invoice.rb:12` | **Lexical scope.** A bare `Calculator` inside `module Billing` resolves to `Billing::Calculator`. |
| `app/models/order.rb:5` | **`class_name:` counted once.** `has_many :invoices, class_name: 'Billing::Invoice'` is one edge, not two. |
| `app/models/audit_event.rb` | A **polymorphic** `belongs_to`. The name is an interface, not a constant — inferring `Auditable` from it would point an edge at something that does not exist. |
| `app/services/fulfillment/packer.rb` | A **facade leak** — outside code naming a domain's internals. |
| `app/models/ledger_entry.rb` | A domain member **no naming convention reveals**: a top-level constant that belongs to Billing. This is why `.extract-scout/domains.json` has to exist. |

## The hook demo

`.extract-scout/domains.json` is checked in with `Billing` and `Fulfillment` at
`"enforce": true`. That is not what `/extract-scout` writes — the scout always writes
`"enforce": false`, because recording a boundary is not the same as deciding to defend one.
Here it is pre-decided so the hook demo works on a fresh clone.

Restart Claude Code after cloning (hooks load at session start), then add a crossing
association to `app/models/ledger_entry.rb`:

```ruby
belongs_to :order
```

`LedgerEntry` is Billing, `Order` is Fulfillment, and nothing in either name says so — which is
the case namespace inference alone cannot catch.

Adding `has_many :pick_lists, class_name: 'Fulfillment::PickList'` to `order.rb` instead stays
silent: same domain, nothing to say.
