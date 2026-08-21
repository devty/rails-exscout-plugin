# Open questions

Questions a reviewing engineer would ask about `extract-scout` as a Claude Code plugin, drawn from
watching it run the DocuSeal sweep (2026-08-21). These are review questions, not bug reports — the
bugs are in [`postmortem-docuseal-sweep.md`](postmortem-docuseal-sweep.md).

Ordered roughly by how hard they are to answer well.

---

## On correctness and evaluation

### 1. What is the false-positive rate, and is it measured anywhere?

Measured on this one repo, before the fixes: cycle detection **1 of 1 false**; `string_coupling`
**8 of 22 false**; association edges **18 of 118 silently dropped**. After D1–D6: no known false
positive, string refs 100% genuine, 7 deliberate drops.

Those after-numbers are the problem this question is really about. They are measured on the **same
repo the defects were found in**, which is the weakest possible evidence that the fixes generalise.

`test/` has 7 files and a `verdict_matrix.rb`, which is real discipline for a plugin this size. But
they are unit tests over synthetic fixtures — they assert the analyzer does what it was written to
do. None of the four defects above would fail any of them, because each is a case the fixtures do not
contain (multi-line associations, `polymorphic: true`, disjoint-file namespace cycles).

The gap is a **corpus**: a handful of real open-source Rails apps, checked in as pinned refs, with
hand-labeled ground truth for at least "which associations exist and what do they point at." That is
the eval that would have caught D1 the day it was written.

### 2. The SKILL says "never invent a citation." The indexer invents constants. Why is that a
different standard?

`skills/extract-scout/SKILL.md` — *"Never invent a citation. Every `file:line` must come from script
output or a file you actually read. A fabricated line number destroys trust in the whole report."*

Correct, and well-placed. But it governs the **model**, and the deterministic layer beneath it is
held to no equivalent standard. `app/models/account.rb:53 → ActiveUser` is a citation with a precise
line number pointing at a constant that does not exist. It is *precisely wrong*, which is the failure
mode the rule exists to prevent — arriving through the layer nobody thought to point the rule at.

The generalizable version: **the integrity rules a skill writes for its model should also be
enforced against the tools the skill trusts.** A tool that returns confident garbage launders it
through a model instructed to trust tool output.

### 3. Is the score comparable across repos, or only within one?

`Verdict.score` saturation constants are absolute: 3 cycle units, 12 exposed constants, 10 inbound
units, 10 boundary associations, 12 outbound units, 5 string couplings.

On a 34-model app, `inbound_units: 10` is a third of the codebase. On a 400-model monolith it is
noise. So "`Account` scores 4.7" means something different in each, and nothing about the output says
so. If the score is repo-relative, the docs should say it and comparisons across repos should be
discouraged. If it is meant to be absolute, the constants need justification.

Related: 23 of 34 DocuSeal domains scored `Clean` (< 2.0). A scale where two-thirds of the population
lands in one bucket has limited resolution — though this may be honest signal, since most of those
models genuinely are leaves.

### 4. What happens on a repo the conventions do not fit?

`DEFAULT_EXCLUDES`, `DEFAULT_UBIQUITOUS` and the autoload-root globs encode Rails conventions.
DocuSeal is textbook Rails, so this was never tested in anger. Open:

- Rails engines and `packs/` (Packwerk) — `APP_ROOTS` mentions `engines` and `packs`, but is the
  boundary semantics right, given Packwerk already has an explicit, better-informed idea of what a
  domain is? Should the tool *read* `package.yml` instead of competing with it?
- Zeitwerk custom inflections (`acronyms`, `inflect`) — `Inflect` is hand-rolled with a 15-entry
  irregular table. A repo with `API`/`OAuth` acronym rules will mis-resolve.
- Non-Rails Ruby. The SKILL handles this ("note that Rails autoload conventions may not apply") but
  path-based resolution silently weakens rather than failing.

The `files_indexed < 20` tripwire is a good instinct. Is one tripwire enough? A second — *"N% of
constant references failed to resolve"* — would catch inflection mismatches, and would have caught
D1 (see blind-spots #11).

---

## On the agent / deterministic split

### 5. Is the boundary between script and agent in the right place?

The split is mostly excellent and worth keeping as a reference design: **parsing and graph math are
deterministic; boundary judgment and call-site interpretation are agents.** Ripper tokenizing is
exactly what a model should not be doing, and "does `Invoice` belong to Billing" is exactly what a
script cannot decide.

One thing sits on the wrong side. The **interpretation of each edge kind** is hardcoded English in
`analyze_domain.rb`:

> *"Constantized strings, routing targets and job class names are invisible to every refactoring
> tool. These break at runtime, in production, not at boot."*

On DocuSeal that sentence was attached to 8 `class_name:` options, for which it is false. The prose
is a *judgment about evidence* frozen into the layer that cannot revise it, and the model downstream
is instructed to preserve the script's ordering and reasoning. The claim and the evidence should be
separable — the script reports the kind and the citations; the severity language adapts to what the
citations turn out to be.

### 6. Why is the model doing arithmetic the script should own?

The sweep produced 34 JSON files, aggregated with ad-hoc Ruby one-liners written in the conversation:
sorting by score, grouping severity, computing hub/leaf tiers, building the markdown table. All
deterministic, all re-derived from scratch, all consuming model context.

A `--summary` / `--domains-from` mode would move it into the script, make the ranking reproducible
without a model, and remove a class of transcription error. See postmortem § Ergonomics.

### 7. Should Step 4's skip threshold be on file count?

The SKILL skips seam-analyst dispatch below ~5 files. Every DocuSeal domain was 1 file, so the agent
layer — described in the skill's own preamble as the point of the report — never ran across 34
invocations.

The manual reading that replaced it produced D1, D2 and D4. That is evidence the step earns its keep
and that file count is the wrong axis; **seam count or severity** would be better. A 1-file domain
with a `blocker` cycle is exactly when you want a human-grade read of the call sites.

### 8. What does the boundary-resolver trigger actually key on?

Both skills say *"fewer than 3 files resolved → dispatch `rails-boundary-resolver`"*, and
`extract-compare` strengthens it to *every* such domain. All 34 DocuSeal domains resolved to one file
— a literal reading dispatches 34 agents against boundaries that were already exact.

The signal that distinguishes them is already in the JSON: `evidence`. `path`-only is a name
coincidence; `constant` + `path` (all 34 here) is strong. The SKILL's own bullet list gets this right
one line below where it gets it wrong. Worth resolving before someone follows the instruction
literally and burns 34 agent invocations.

---

## On the hook

### 9. What is the hook's real-world signal-to-noise, and who validates the file it trusts?

This one bit during the sweep, and it is the most interesting finding in this document because
**following the skill correctly produced the failure.**

The hook's stated design constraint #1: *"SILENT unless there is something real to say. This runs on
every edit; a hook that cries wolf gets switched off within a day and then protects nothing."*

Its warn condition (`check_cross_domain.rb:~225`) fires when a new association targets a *different
identified domain*, and identity comes from `.extract-scout/domains.json`. SKILL Step 6 instructs the
scout to write every domain it resolves into that file.

So the 34-model sweep wrote 34 single-model domains — and every model in DocuSeal is now an
"identified domain." **Any** new `belongs_to` or `has_many` between any two DocuSeal models now
warns. The file that exists to make the hook precise has made it fire on ordinary Rails.

The root cause is a conflation: `domains.json` serves as both *"what I measured"* and *"what I want
defended,"* and those are not the same set. A per-model sweep is a measurement. Suggested fixes, in
order of preference:

1. Separate the artifacts — a sweep writes `measurements.json`; only a deliberate decision writes
   `domains.json`.
2. Add `enforce: false` per domain, defaulting to false for anything the scout wrote automatically.
3. At minimum, have Step 6 warn when it is about to write more than a handful of domains, and have
   the hook stay silent when both sides are single-file domains.

**Verified, not inferred.** With the 34-domain file in place, adding an ordinary association to
`app/models/template.rb`:

```
$ echo '{"tool_name":"Edit","tool_input":{"file_path":".../app/models/template.rb",
  "old_string":"x","new_string":"  has_many :submissions, dependent: :destroy"},"cwd":"..."}' \
  | ruby hooks/scripts/check_cross_domain.rb

extract-scout: new cross-domain association
  app/models/template.rb  (Template -> Submission)
    has_many :submissions, dependent: :destroy
```

`Template has_many :submissions` is not an architecture violation in DocuSeal — it is the schema.

### Latency — measured, and the fix is not where you would guess

macOS arm64, Ruby 3.3.0, 10 invocations each:

| path | per-invocation |
|---|---|
| association present (parser loads, full analysis) | ~108 ms |
| no association (cheap pre-filter exits early) | ~115 ms |
| bare `ruby -e ''` — interpreter startup floor | ~95 ms |

The pre-filter at `check_cross_domain.rb:196` is well-intentioned and **buys nothing measurable**:
~95ms of the ~110ms is `ruby` process startup, and `require_relative` of the 512-line
`build_index.rb` costs ~13ms on top. Constraint #2's "tens of milliseconds" budget is missed by ~4×,
and no amount of work-avoidance inside the script will fix it — the cost is paid before the first
line executes.

If the budget matters, the lever is process model, not algorithm: a long-lived helper, or accepting
~110ms as the floor for any Ruby-based `PostToolUse` hook and documenting it.

### The blanket rescue is indistinguishable from success — demonstrated accidentally

`rescue StandardError; exit 0` is the right call for constraint #1: a hook must never break the
user's tools. But there is no observable difference between *"analyzed, nothing to say"* and
*"crashed on line one."*

This was not a theoretical concern during the sweep. A malformed payload (zsh's builtin `echo`
interpreting `\n` inside the JSON string, corrupting it) made `JSON.parse` raise, the rescue
swallowed it, and the hook exited 0 — identically to a clean pass. The first conclusion drawn was
"the hook does not fire on ordinary associations," which is the **opposite** of the truth, and it
took a line-by-line `exit 0` trace to find out.

If that can mislead someone actively investigating the hook, a silently-broken hook in normal use
will never be noticed at all. D1 shows the shared `FileAnalyzer` can be wrong; a parser regression
would degrade this hook to a permanent no-op with no signal.

**Suggested:** `EXTRACT_SCOUT_HOOK=debug` that writes the exception and the exit path to stderr, and
a one-line self-test the SKILL can run after writing `domains.json` to confirm the hook still fires.

### 10. Does "shared definitions" double the blast radius of a parser bug?

Constraint #3 — the hook reuses `build_index.rb`'s `FileAnalyzer` so the hook and `/extract-scout`
"can never disagree about what an association is" — is good design, and it is why the two surfaces
stay consistent.

The corollary is that D1 is not one bug in one report; it is the same misparse in the report *and* in
the live guard. A multi-line `class_name:` association is misread identically by both. Consistency
is the right trade, but it raises the value of the corpus eval in Q1 by roughly a factor of two.

---

## On product framing

### 11. Who is this for, and does the output match?

Two different readers are implied. *"An engineer will not act on 'Billing is 6/10 coupled'"* argues
for citations and specificity. The `verdict` string — *"one sentence a tech lead could repeat in a
planning meeting"* — argues for a number a manager can compare.

The DocuSeal report ended up serving neither cleanly: 34 individual reports were not what anyone
wanted, and the synthesis that answered the actual question (a ranking table plus a runtime-surface
section) is not a shape the tool produces. Is there a missing third artifact — a **portfolio view**
across all domains — sitting between `/extract-scout` (one domain, deep) and `/extract-compare` (a
few candidates, ranked)?

### 12. Does the tool know what it is being used *for*?

Its advice assumes extraction to another Ruby service. The DocuSeal question was extraction to
**Node**, where "promote the concern to a shared library" and "confirm the FK in schema.rb" mean
different things or nothing. See blind-spots #10.

A `--target ruby-service|other-language|modular-monolith` flag would change which seams matter — for
a same-language modular monolith, `serialize` and `encrypts` are free and cycles dominate; for a
cross-language port, cycles barely matter and the runtime surface is everything. On DocuSeal the tool
ranked precisely the axis that did not decide the answer.

### 13. Is `not_analyzed` doing its job, or absorbing scope creep?

It worked here — it is what prompted looking past the graph, and it is the reason the engagement
produced a correct answer. That is a genuine design win and the list should stay.

The risk is that it becomes a place to park things rather than build them. Three of its four entries
(schema FKs, transactions, git co-change) are *statically derivable from files already in the repo*.
At some point "not analyzed" stops reading as honesty and starts reading as a backlog. Worth deciding
which of the four are permanent scope boundaries and which are TODOs, and saying which is which.
