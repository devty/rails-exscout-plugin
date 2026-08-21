# Postmortem: the DocuSeal 34-model sweep

**Date:** 2026-08-21
**Repo under test:** [docuseal](https://github.com/docusealco/docuseal) at `004a22c1` — Rails 7, 304
indexed `.rb` files, ~25,000 LOC across `app/` + `lib/`, 34 models.
**Plugin version:** `dcd3dec` (`Add test suite; fix mixin misclassification on receiver calls`).
**Task:** decide whether DocuSeal is suitable to migrate from Rails to Node.
**Method used:** `analyze_domain.rb` run once per model — a literal per-model domain, 34 runs, rather
than clustered conceptual domains.

This is a field report on how the plugin performed, written from the actual run. Every defect below
is reproducible from the artifacts in the DocuSeal repo (`tmp/extract-scout/index.json`).

---

## Summary

The plugin's **architecture is right and its arithmetic is wrong.**

The design decisions that were hard to get right — splitting magnitude from blocking, refusing to
call inverse association pairs a cycle, scoring on caller breadth rather than edge count, printing a
`not_analyzed` clause — all held up under 34 consecutive runs and are the reason the output was
usable at all. Without the inverse-pair rule alone, all five hub models would have printed `BLOCKED`
and the report would have been worthless.

The parsing layer underneath them has a defect that silently drops **15.3% of all association edges**
and manufactures phantom string couplings from the same source lines. The conclusions of the DocuSeal
analysis survive it, because the dropped edges point into hubs that already ranked top. The *numbers*
do not.

The plugin also did not answer the question that was actually asked. It reported that DocuSeal's
model graph is nearly acyclic — true, verified, and not the deciding factor. What decides a
Rails→Node port is ActiveRecord Encryption, ActiveStorage, `serialize`-into-text-columns, polymorphic
discriminators and application-level column defaults. None of that is in the tool's output model,
and none of it is in `not_analyzed` either, so the report did not even disclaim it.

---

## What worked

These are not courtesy notes. Each was a live decision point where the tool could have produced a
wrong answer and did not.

### 1. The magnitude/blocking split (`bab7fcc`) was validated at n=34

Across 34 domains, no report printed a `Clean` label above a `[BLOCKER]` seam. The one blocked
domain printed `Moderate, but BLOCKED` — magnitude and blocking disagreeing, which is exactly the
case the split exists for. Verdict distribution: 23 `Clean`, 7 `Moderate`, 3 `Hard`, 1
`Moderate, but BLOCKED`.

The comment at `scripts/analyze_domain.rb:~420` predicting the failure mode ("an earlier build scored
one true cycle at 1.1/10 and printed *Clean — extractable as-is* directly above *[BLOCKER] Cycle*")
describes a real trap that this repo would have walked into.

### 2. Inverse-pair separation prevented a total false-positive cascade

`Account` alone has **15 inverse association pairs**. `User` has 8, `Template` 8, `Submitter` 5,
`Submission` 4. A tool that treats bidirectional association as a cycle would have reported every hub
model as `blocker`, on the most standard idiom in Rails.

`BEHAVIORAL_KINDS` (`analyze_domain.rb:~117`) and the `behavioral?` partition are the reason it did
not. This is the single highest-value correctness decision in the codebase.

### 3. Scoring on `inbound_units`, not `inbound_edges`

`LockEvent` has **18 inbound edges from 1 distinct caller**. Scored 0.4, labeled `Clean`. Correct —
that is repeated reference from one place, not breadth. A naive edge-count tool ranks `LockEvent`
above `SubmissionEvent` (10 edges, 8 callers), which would be backwards.

### 4. `shared_mixin` correctly never fired — a true negative

Zero `shared_mixin` seams across 34 domains. Verified independently: `grep '^\s*include\|^\s*extend'
app/models/*.rb` returns nothing, and `app/models/concerns/` does not exist. DocuSeal genuinely uses
no model mixins. The `dcd3dec` receiver-call fix appears to hold.

### 5. Boundary resolution was exact, 34/34

Every domain resolved to exactly one file, with **both** `constant` and `path` evidence. No
name-collision false inclusions, no missed files. `Submission` did not swallow `SubmissionEvent`;
`Template` did not swallow `TemplateFolder`, `TemplateVersion`, `TemplateAccess` or `TemplateSharing`
— the exact-match-or-`::`-prefix rule in `DomainResolver#resolve` is doing real work on a repo with
heavily shared name prefixes.

### 6. The `not_analyzed` clause changed the outcome

This is the feature that made the engagement succeed. Reading "schema foreign keys… transaction
boundaries… runtime config" is what prompted going to look at what else the graph could not see —
which is where the actual answer was. A tool that had silently implied completeness would have
produced a confidently wrong recommendation.

### 7. Operational reliability

34 invocations, zero crashes, zero malformed JSON, deterministic across reruns. Index build over 304
files completes in under a second. stdlib-only, no Rails boot required — which is what made a
34-domain sweep practical at all.

---

## Defects

### D1 — `class_name:` is not parsed on multi-line associations `[high]` — **FIXED**

> **Status: fixed.** `scan_for_class_name` now walks to the end of the logical statement, and strings
> consumed as a `class_name:` value are suppressed from `maybe_dsl_string`. Seven regression tests in
> `test/test_file_analyzer.rb`. Measured effect on DocuSeal below.

**Not an unknown bug — a known limit whose field impact was unmeasured.**
`test/test_file_analyzer.rb` already carried a characterization test,
`test_class_name_on_a_continuation_line_falls_back_to_inference`, commented *"Known limit, asserted
so a future change to `scan_for_class_name` is a deliberate improvement rather than an accident."*
That is good practice and it is why the fix was safe to make.

What the characterization test did not capture is the **second-order effect**: the orphaned
`class_name:` string is re-detected by the unrelated `maybe_dsl_string` scanner as a phantom coupling
on its *own* line, and `dedupe!` keys on `[const, line]`, so it cannot merge the two. One miss
corrupted the count in both directions simultaneously. Nor did anyone know the rate: 15.3% of all
association edges on a real repo, concentrated in the hub models.

**Original location:** `scripts/build_index.rb`, `scan_for_class_name`.

```ruby
while j < tokens.length && tokens[j][0][0] == line
```

The scan terminated at the end of the **physical line** holding the association symbol. Rails
associations routinely wrap across lines, and DocuSeal's do.

**Ground truth** (`app/models/account.rb:40-42`):

```ruby
has_many :account_testing_accounts, -> { testing }, dependent: :destroy,
         class_name: 'AccountLinkedAccount',
         inverse_of: :account
```

**What the index recorded:**

| line | kind | const |
|---|---|---|
| 40 | `association` | `AccountTestingAccount`  ← fabricated, does not exist |
| 41 | `dsl_string` | `AccountLinkedAccount`  ← phantom, from the orphaned string |

The single bug fires twice, in opposite directions:

1. **Associations are under-counted.** The inferred constant (`AccountTestingAccount`) does not exist
   in the index, so `ConstantResolver#resolve` returns `nil` and `Analyzer#analyze` drops the edge
   with `next unless hit`. **18 of 118 association refs (15.3%) name a non-existent constant and are
   silently discarded.** Fabricated names observed: `DefaultTemplateFolder`, `AccountTestingAccount`,
   `LinkedAccountAccount` (×2), `LinkedAccount`, `TestingAccount`, `ActiveUser`, `SchemaDocument`,
   `SchemaDynamicDocument`, `TemplateSchemaDocument`, `TemplateSchemaStaticDocument`,
   `TemplateSchemaDynamicDocumentVersion`, `TemplateSchemaDynamicDocumentAttachment`,
   `StartFormSubmissionEvent`, `ActiveTemplate`.
2. **String couplings are over-counted.** The orphaned `class_name: 'AccountLinkedAccount'` string is
   then picked up by the unrelated `maybe_dsl_string` scanner, producing a `dsl_string` edge — which
   fires the `string_coupling` seam at `major`, with prose asserting these "break at runtime, in
   production, not at boot." That is **false** for a `class_name:` option, which Rails resolves at
   boot and which every Rails-aware tool understands.

**Blast radius.** The drops concentrate in exactly the models the analysis ranked on: `Account` (7),
`Submission` (4), `Template` (2), `Submitter` (1), `TemplateFolder` (1), `EmailEvent` (1),
`SearchEntry` (1), `WebhookEvent` (1). Of the 22 surviving cross-boundary `dsl_string` edges, **8 are
this false positive**.

**Effect on the DocuSeal conclusions.** Directionally survivable, numerically not. The dropped edges
point *into* `AccountLinkedAccount`, `TemplateFolder`, `User`, `Template`, `SubmissionEvent`,
`DynamicDocument` — hubs and mid-tier that already ranked where they rank. The star topology and the
zero-cycle finding hold. Every association count in the report is an **under**-estimate.

**The fix as shipped.** Stop at an `:on_nl` at bracket depth 0. Both halves are load bearing:
Ripper lexes a newline after a trailing comma as `:on_ignored_nl`, which handles the common wrap, but
a newline *inside* a brace-delimited option is still `:on_nl` — so depth is what stops the scan from
ending one option early. `:on_tlambeg` (the `{` of `-> { }`) must be in the opener set alongside
`:on_lbrace` (the `{` of `lambda { }` and of a hash), since both close with `:on_rbrace` and an
unbalanced count runs the scan off the end of the statement.

Separately, `@consumed_strings` records the token index of any string taken as a `class_name:` value,
and the main loop skips `maybe_dsl_string` for it. Token index, not `[line, value]` — exact, and
immune to the same string appearing twice.

**Measured effect on DocuSeal** (re-indexed at the same commit):

| | before | after |
|---|---|---|
| association refs naming a non-existent constant | 18 / 118 (15.3%) | **10 / 118 (8.5%)** |
| `boundary_assocs` summed over 34 domains | 196 | **212** |
| `string_couplings` summed over 34 domains | 25 | **9** |
| `cycle_units` | 1 | 1 *(D4, untouched)* |

The 9 surviving string couplings are exactly the 9 genuine polymorphic `record_type` sites — the
metric went from ~41% precision to 100% on this repo. All 10 remaining drops are other defects:
`Emailable` and `Record` are **D2** (polymorphic), `LinkedAccount`, `TestingAccount` and the four
`TemplateSchema*` are **D6** (`through:`), and `ActiveStorage::Attachment` is a correctly-read
`class_name:` pointing at a gem constant — not a fabrication, and arguably the fix working.

Ranking impact: the hub *set* is unchanged, but the order within it moved. `Account` fell from 1st
(4.7) to 3rd (4.2) — it *gained* 5 associations and *lost* all 5 string couplings, having been fully
saturated on the 0.5-weight string term by evidence that was entirely false. `Submitter` and
`Template` now lead at 4.4. That a single parse bug reordered the top of the ranking is the argument
for the corpus eval in `open-questions.md` Q1.

**Regression tests added** (`test/test_file_analyzer.rb`): continuation-line override, exactly-one-edge,
override after a `-> { }` lambda plus trailing options, override after a multi-line brace option,
override after a multi-line `lambda { }` keyword block, no leakage from the following statement, and
constants inside the scope lambda still recorded as references.

---

### D2 — Polymorphic associations produce garbage and are then dropped `[high]` — **FIXED**

`belongs_to :record, polymorphic: true` (`app/models/search_entry.rb:27`) infers the constant
`Record`. `belongs_to :emailable, polymorphic: true` (`app/models/email_event.rb:32`) infers
`Emailable`. Neither exists; both edges are discarded.

The consequence is inverted from what an extraction tool should do. A polymorphic association is the
**hardest** association to extract — no foreign key, a string discriminator, an open-ended target set
— and it is the one the tool is completely blind to. `SearchEntry` reports **zero** association edges
to the four models it actually indexes.

Worse, the coupling shows up somewhere the reader will discount it. DocuSeal queries these
discriminators as bare strings in nine places across `lib/` — `SearchEntry.where(record_type:
'Submission')` at `lib/submissions.rb:64`, and similar at `lib/submissions.rb:73`,
`lib/submitters.rb:44,84`, `lib/templates.rb:78,100`,
`lib/submitters/normalize_values.rb:311`,
`lib/submitters/maybe_assign_default_browser_signature.rb:10`, and
`app/controllers/api/templates_controller.rb:87`. These land in `string_coupling`, mixed in with D1's
eight false positives, at `major` — the same severity 32 of 34 domains got for having any
association at all.

**The fix as shipped**, which differs from the recommendation above. Rather than pointing the edge at
the *discriminator*, the target set is resolved for real. A polymorphic interface has two halves and
both are in the repo: `belongs_to :record, polymorphic: true` declares it, and
`has_one :search_entry, as: :record` implements it. `FileAnalyzer` records both halves per file, and
the `Indexer` — which is the layer that has seen every file — pairs them and emits `kind:
'polymorphic'` edges from the declaring model to each concrete implementor.

The pairing key is `[owner_constant, interface_name]`, **not** the bare interface name. The
association's own target (`has_one :search_entry` → `SearchEntry`) names the owner, so two models
that both declare a `:record` interface stay distinct. That precision matters here: DocuSeal has
exactly that collision.

The fabricated name-inferred constant is no longer emitted at all — for a polymorphic association
there is no single class to infer.

`kind: 'polymorphic'` is deliberately in neither `ASSOCIATION_KINDS` nor `BEHAVIORAL_KINDS`: it must
not dilute the association count, and an inverse polymorphic pair must not be promoted to a cycle.
Both are pinned by tests.

**Unbounded interfaces are reported, not omitted.** An interface nobody implements produces no edges,
so an edge-only metric would make the *least* bounded case the quietest one in the report. The
declaration is kept on the file entry, and `analyze_domain` reports it separately.

**New seam.** `polymorphic`, weight 90 — ranked directly below `cycle` (100) and above `facade_leak`
(60). A cycle stops you drawing the boundary at all; a polymorphic association lets you draw it and
then cannot survive it. Severity is `blocker` when implementors cross the boundary, `major` when the
interface is unbounded. `polymorphic_edges` and `polymorphic_unbounded` join the metrics block.

**Measured effect on DocuSeal:**

| | before | after |
|---|---|---|
| association refs naming a non-existent constant | 10 | **7** |
| domains whose `max_severity` is `blocker` | 1 *(the D4 false positive)* | **6** |
| `boundary_assocs` | 232 | 232 — not diluted |
| `cycle_units` | 1 | 1 — no false cycles from the new pairs |

Resolved: `SearchEntry:27 → Submission, Submitter, Template`; `EmailEvent:32 → Submitter`.
`WebhookEvent:29` declares `:record` with **zero** implementors anywhere in the repo and is now
reported as unbounded — previously it was silently nothing.

The five newly-blocked domains are `SearchEntry`, `EmailEvent`, `Submission`, `Submitter` and
`Template`. This is the fix that most changes what the tool is worth: the polymorphic coupling in
DocuSeal was originally found by *hand-reading* `app/models/*.rb` after the graph analysis came back
clean, and it became §4 of the migration report. The tool now finds it structurally, at `blocker`,
without anyone reading a model.

It also partly answers **D3**: `blocker` went from 1 domain to 6, so the severity axis now
discriminates instead of being pinned at `major` for everything with an association.

**Still open.** The far end of a `dsl_string` comparing a discriminator (`SearchEntry.where(record_type:
'Submission')`, 9 sites in DocuSeal) is still counted under `string_coupling` rather than being
promoted into the polymorphic seam. Those two findings describe one problem and should be linked.

---

### D3 — `max_severity` is saturated and carries almost no signal `[high]` — **FIXED**

The `boundary_assoc` seam is hardcoded `'severity' => 'major'` and fires on `if assoc.any?`.

Distribution across 34 domains:

| max_severity | count |
|---|---|
| `major` | 31 |
| `blocker` | 1 |
| `moderate` | 1 |
| `nil` | 1 |

For **22 of the 31**, `boundary_assoc` was the *only* major seam — the domain was labeled `major`
purely for having at least one association crossing its boundary. On a Rails app, every model does.
`AccountAccess` (1 inbound edge, 25 LOC, 3 associations) and `Account` (36 inbound edges, 32 callers,
36 associations) print the same severity.

Since `blocked?` is defined as `max_severity == 'blocker'`, the enum's *bottom* two values are noise
and only the top carries information — a 3-value scale doing 2 values of work, one of which fired
once in 34 runs and was wrong (see D4).

**The fix as shipped.** `boundary_assoc` severity now scales with crossings per domain file:
`major` at 5 or more, `moderate` below. A typical Rails model declares two to four associations, so
five per file is genuinely past the norm and below it is ordinary Rails. It is never `blocker` — an
association crossing is work to do, not a precondition for drawing the boundary. The `why` text now
states the ratio and the threshold, so the reader can disagree with the cut rather than guess at it.

Combined with D2 (which added a real `blocker`) and D4 (which removed a false one), the axis now
discriminates:

| max_severity | before | after |
|---|---|---|
| `blocker` | 1 *(false positive)* | **5** *(all genuine polymorphic)* |
| `major` | 31 | **10** |
| `moderate` | 1 | **18** |
| none | 1 | 1 |

`AccountAccess` (3 associations, 25 LOC) and `Account` (43 associations) no longer print the same
severity.

---

### D4 — `unit_of` collapses namespaces, manufacturing cycles `[medium]` — **FIXED**

**Location:** `analyze_domain.rb`, `unit_of` (~line 176) — `const.split('::').first`.

`WebhookUrls::Signatures` and `WebhookUrls` become one unit. The sweep's **only** `blocker` was the
false positive this produces:

- Inbound: `lib/webhook_urls.rb:29,39,44` → `WebhookUrl`
- Outbound: `app/models/webhook_url.rb:60` → `WebhookUrls::Signatures`

`app/models/webhook_url.rb:60` is `self.hmac_secret ||= WebhookUrls::Signatures.generate_secret`.
`lib/webhook_urls/signatures.rb` is a pure HMAC/secret helper containing **zero** references to
`WebhookUrl` (verified by grep). The inbound and outbound file sets are **disjoint**. At file
granularity there is no cycle, and there is no cycle anywhere in DocuSeal's model layer.

On this repo, cycle detection's false-positive rate was **1 of 1**.

The trade-off is deliberate and defensible — unit granularity is what makes `Submissions` read as one
service module rather than nine files — but the failure mode is not currently detected.

**The fix as shipped.** Behaviour in both directions is necessary but not sufficient. A unit is a
whole namespace, so the bidirectionality has to be shown at file granularity: a cycle is reported
only when the set of external files that *call in* intersects the set that gets *called back*. When
those sets are disjoint, the finding is demoted to a new `namespace_pair` seam at `major`
(weight 65), whose text says exactly why it is not a cycle and what would make it one.

The existing behavioural-cycle test still passes — its fixture has the same file on both sides, which
is a real cycle and still reported as one.

**Measured effect on DocuSeal:** `cycle_units` across all 34 domains went 1 → **0**. `WebhookUrl`
went from `3.7 — Moderate, but BLOCKED` to `2.7 — Moderate` with a `namespace_pair` seam. There is
now no false positive anywhere in the sweep.

---

### D5 — `maybe_dsl_string` fires on any capitalized string literal `[medium]` — **FIXED**

`maybe_dsl_string` (`build_index.rb:~360`) records a constant reference for any string matching
`/\A[A-Z][A-Za-z0-9_]*(::...)*\z/` longer than 2 characters, regardless of syntactic context.

**381 `dsl_string` refs recorded repo-wide; 359 (94%) resolve to nothing** and are discarded. Noise
observed: `attribute :timezone, :string, default: 'UTC'` → const `UTC`; `PRODUCT_NAME = 'DocuSeal'`
→ `DocuSeal`; `'Checkbox'` / `'Field'` inside a PDF label template at
`lib/templates/detect_fields.rb:215` → `Field`.

Of the 22 that *do* resolve: 9 genuine (D2's polymorphic discriminators), 8 false (D1), 5 noise that
happens to collide with a real constant (`DocuSeal` ×3, `Field`, and Devise's `parent_mailer`
config). Precision on the surviving set is roughly **41%**.

The unresolvable 94% is harmless to the metrics but triples index size and makes the `dsl_string`
kind untrustworthy as a signal.

**The fix as shipped.** A capitalised string is recorded only when something gives it that meaning:

- a label matching `*_type:` — Rails' polymorphic discriminator → `polymorphic_ref`
- a comparison (`==`, `!=`, `<=>`) against an identifier matching `*_type` → `polymorphic_ref`
- a `class_name:` / `job_class:` / `parent_mailer:` / `serializer:` label → `dsl_string`
- a `.constantize` / `.safe_constantize` receiver → `dsl_string`
- a routing target of the form `a/b#c` → `dsl_string`
- otherwise, only if the string contains `::` → `dsl_string`

The `::` rule is deliberate and ordered **after** the context checks, not before: prose almost never
carries a scope operator, so a namespaced string is evidence on its own — but
`record_type: 'Billing::Invoice'` is still a discriminator, and checking shape first would have
misfiled it. That ordering bug was caught by a test fixture, not by review.

**This is also where D2's loose end closed.** Discriminator strings get their own kind,
`polymorphic_ref`, and are counted with the polymorphic seam instead of under `string_coupling`.
The association and the string comparison are one problem; reporting them in two places made the
string half read as unrelated boilerplate.

**Measured effect on DocuSeal:**

| | before | after |
|---|---|---|
| `dsl_string` refs recorded | 372 | **6** |
| `polymorphic_ref` refs | — | **11** |
| unresolvable (pure noise) | 358 (96%) | 8 |
| resolvable **and** genuine | 14 of 22 (~64%) | **9 of 9 (100%)** |
| `string_couplings` over 34 domains | 9 | **0** — all reclassified |

All nine genuine discriminator sites survive and are now attached to the seam they belong to.
`'UTC'`, `'DocuSeal'`, `'Checkbox'` and `'Field'` are gone.

---

### D6 — `through:` associations resolve to the wrong constant `[low]` — **FIXED**

> **Status: fixed.** A `through:` association now also emits an edge to the join model, resolved
> through an in-file association map that follows `through:` chains. Seven regression tests.

`has_many :linked_accounts, through: :account_linked_accounts` (`app/models/account.rb:51`) recorded
`LinkedAccount`, which does not exist; dropped. Same for `:testing_accounts` at line 52.

**The insight that shaped the fix.** A `has_many :through` carries *two* real dependencies:

1. **the join model** — always named in this file, always resolvable;
2. **the far end** — decided by the `source:` association *on the join model*, so it needs
   cross-file resolution the single-file `FileAnalyzer` cannot do.

The old code emitted only a guess at (2), inferred from the association name. When that guess was
wrong the edge resolved to nothing and was dropped — so a wrong guess at the far end also destroyed
the join dependency, which was never in doubt.

**The fix as shipped.** Keep emitting the name-inferred far end — it is right often enough to be
worth having (`template.rb:75` genuinely does return `DynamicDocumentVersion`) and costs nothing when
wrong, since `ConstantResolver` already drops unresolvable constants. **Additionally** emit the join
edge, resolved via a map of association-symbol → class built from the same file. Through associations
are deliberately kept *out* of that map and in a separate `@assoc_through`, so a chain follows to the
base rather than stopping at a name-inferred constant. A `seen` list terminates self- and
mutually-referential chains.

**Measured effect on DocuSeal**, all 10 new edges verified correct against the source:

| | post-D1 | post-D6 |
|---|---|---|
| association refs recorded | 118 | **128** |
| refs naming a non-existent constant | 10 (8.5%) | 10 (7.8%) |
| `boundary_assocs` over 34 domains | 212 | **232** |
| `inbound_edges` over 34 domains | 432 | **442** |
| `cycle_units` | 1 | 1 — no false cycles introduced |

The 10 recovered edges: `account.rb:51,52 -> AccountLinkedAccount`; `submission.rb:78,82,86,90 ->
Template`; `submission_event.rb:33 -> Submission`; `submitter.rb:45,61 -> Submission`;
`template.rb:75 -> DynamicDocument`.

`submission.rb:90` is the case that justifies the chain-following: `through:
:template_schema_dynamic_document_versions`, which is *itself* a through association declared four
lines above, resolving two hops to `Template`.

The count of unresolvable constants is unchanged at 10 — those are the far-end guesses, deliberately
kept. What changed is that 10 join dependencies that previously did not exist in the graph at all now
do. Judge this fix on edges *recovered*, not on the drop percentage, whose denominator moved.

**An unintended demonstration of D3.** `Submission`'s boundary associations went 12 → 19, a 58%
increase in measured coupling, and its score did not move at all (3.9 → 3.9) — `boundary_assocs`
saturates at 10 in `Verdict.score`. The domain was already pinned before the real number was known.

---

## Ergonomics

**`extract-compare` is the right entry point for this task and did not get used.** The 34-model
sweep — "I don't know my domains yet, so let me measure every model and find the hubs" — is a
legitimate workflow, and `extract-compare` already takes N domains and indexes once. It was not
reached for because the framing ("rank candidate domains… which one do we do first?") reads as
picking between 2–4 known candidates, not sweeping 34.

**But following it literally would have been actively harmful here.** Both skills contain the rule
*"domains resolving to fewer than 3 files need the `rails-boundary-resolver` agent before their
numbers mean anything"*, and `extract-compare` strengthens it to *"dispatch the agent for **every**
weakly resolved domain."* Every domain in this sweep resolved to exactly **one** file — so a literal
reading dispatches 34 boundary-resolver agents against boundaries that were already exact.

The heuristic conflates *few files* with *badly resolved*. The distinguishing signal is already
computed and already in the JSON: the `evidence` map. `path`-only is weak; `constant` + `path`, which
is what all 34 had, is strong. The SKILL's own Step 3 list gets this right in its third bullet
(`evidence shows only path matches`) and then wrong in its second (`fewer than 3 files resolved`).

**Suggested:** replace the file-count trigger with an evidence-quality trigger, and add an explicit
sweep mode — `analyze_domain.rb --domains-from app/models --format json-lines` emitting one record
per line, plus a `--summary` that produces the ranking table. As run, 34 JSON files were aggregated
with ad-hoc Ruby written in the conversation, which is model-in-the-loop work for something the
script should own.

**Step 4 never ran.** The SKILL auto-skips seam-analyst dispatch below ~5 files, which was every
domain here. Reasonable — but it means the "read the actual call sites" value that the skill's own
preamble calls *the* point of the report came from reading them manually. The D1/D2/D4 findings all
came out of that manual reading, which is evidence the step earns its keep and the skip threshold is
tuned for the wrong axis.

---

## Reproducing

```bash
cd ~/@workspace/docuseal
ruby ~/@workspace/rails-exscout-plugin/scripts/build_index.rb --root . --out tmp/extract-scout/index.json

# D1: association refs naming a constant that does not exist
ruby -rjson -e '
idx=JSON.parse(File.read("tmp/extract-scout/index.json")); c=idx["constants"]
bad=idx["files"].flat_map{|f,m| m["refs"].select{|r| r["kind"]=="association" && !c.key?(r["const"])}.map{|r| "#{f}:#{r["line"]} -> #{r["const"]}"}}
puts "#{bad.size} dropped"; puts bad'

# D5: dsl_string noise ratio
ruby -rjson -e '
idx=JSON.parse(File.read("tmp/extract-scout/index.json")); c=idx["constants"]
all=idx["files"].flat_map{|f,m| m["refs"].select{|r| r["kind"]=="dsl_string"}}
puts "#{all.size} recorded, #{all.count{|r| !c.key?(r["const"])}} unresolvable"'
```

---

## Priority

1. ~~**D1**~~ — **fixed**; drop rate 15.3% → 8.5%, string-coupling precision ~41% → 100%.
   With D6, association edges recorded went 118 → 128 and `boundary_assocs` 196 → 232 (+18%).
2. ~~**D2**~~ — **fixed**; target sets resolved across files, `blocker` domains 1 → 6, unbounded
   interfaces reported. Remaining: link discriminator string comparisons to the polymorphic seam.
3. ~~**D3**~~ — **fixed**; severity scales per domain file. Distribution went 1/31/1 to 5/10/18.
4. ~~**D4**~~ — **fixed**; file-granularity check. `cycle_units` across the sweep went 1 → 0.
5. ~~**D5**~~ — **fixed**; context-gated. String refs 372 → 17, precision ~64% → 100%.
6. ~~**D6**~~ — **fixed**; 10 join dependencies recovered, chain-following verified on real code.

Companion documents: [`blind-spots.md`](blind-spots.md), [`open-questions.md`](open-questions.md).
