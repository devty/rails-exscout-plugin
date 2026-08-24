# Build your own plugin

**Who this is for.** An engineer who watched `/extract-scout` run and thought *"the same shape
would work for the thing my team keeps redoing."* It probably would. This is what to do
about it.

**What you get at the end.** A plugin loaded into your own Claude Code, with one slash command,
one script, one agent, and a contract that keeps the output honest inside a repo none of us has
seen.

Almost none of this is about Rails. To keep that promise visible, the running example is a
different plugin entirely — `/flag-sweep`, *which of our feature flags are dead?* Every org past
about two hundred flags has that question, and answers it the same bad way: somebody greps,
somebody argues, somebody deletes the wrong one.

---

## Fifteen minutes to something loaded

Get a skeleton running before you design anything. It is much easier to argue with a plugin
that exists.

```
flag-sweep/
  .claude-plugin/plugin.json     # the manifest
  skills/flag-sweep/SKILL.md     # /flag-sweep
  scripts/scan_flags.rb          # the deterministic half
  agents/flag-classifier.md      # the judgment half
  hooks/hooks.json               # comes later. See step 5.
```

`.claude-plugin/plugin.json`:

```json
{
  "name": "flag-sweep",
  "version": "0.1.0",
  "description": "Reports which feature flags are dead, with the last reference to each.",
  "author": { "name": "You", "email": "you@example.com" },
  "keywords": ["feature-flags", "cleanup", "tech-debt"],
  "license": "MIT"
}
```

`skills/flag-sweep/SKILL.md` — the frontmatter is the whole interface:

```markdown
---
name: flag-sweep
description: Reports which feature flags in this repo are dead and safe to delete, with the last file:line that referenced each. Use when the user runs /flag-sweep, or asks which feature flags can be removed, which flags are stale, how much flag debt the repo carries, or whether a specific flag is still live.
argument-hint: [--since DAYS]
allowed-tools: Bash, Read, Grep, Glob, Agent
---

# Flag Sweep

...steps go here.
```

Load it with no install and nothing written to disk:

```bash
claude --plugin-dir /path/to/flag-sweep
```

```bash
claude plugin details flag-sweep
```

**Spend real time on `description`.** It is not documentation, it is the retrieval surface —
it decides whether the skill fires at all. Write it in the words *your colleagues* use when they
ask, not the words you use when you describe what you built. "Which flags can we delete" belongs
in there. "Performs static analysis of flag call sites" does not.

That is a working plugin. Everything below is what makes it worth installing.

---

## 1 · Find the work that gets re-derived

Not "what would be cool." The question is: **what does somebody on your team redo by hand, from
scratch, every single time it comes up?**

Three signs you have found one:

- Somebody has pasted the one-liner into Slack before. More than once. Slightly differently each
  time.
- Two people doing it carefully get different answers.
- The answer expires. It was true last quarter and it is wrong now.

And one anti-signal worth taking seriously: if the answer is stable and the same for everyone,
you want a document, not a plugin. Plugins earn their keep on work that has to be *redone*.

For flag-sweep, the question is asked every cleanup week, answered with `grep`, and wrong in a
specific direction — `grep` finds the flag name in source and misses the flag whose key is
assembled at runtime, and it cannot tell a dead flag from a kill switch that is supposed to sit
at `false` forever.

That last clause is the important one. **Name the specific direction the manual answer is
wrong in.** It is the thing your plugin has to beat, it is the first sentence of your README,
and if you cannot name it, you do not yet have a plugin worth building.

---

## 2 · Draw the line between script and agent

This is the decision the whole thing rests on.

The test is one question: **should two people running this get the same answer?**

If yes, it is a script. If the answer requires reading code in context and forming a view, it is
an agent.

| | script | agent |
|---|---|---|
| extract-scout | lex with Ripper, resolve constants, count edges, separate true cycles from inverse pairs | does `TaxEngine` belong to Billing? is this cycle a one-line injection or a redesign? |
| flag-sweep | find every reference to every flag key, join against the provider's flag list, compute last-referenced dates | is this zero-reference flag dead, or is it the kill switch we page on? |

Both directions of getting this wrong hurt, and they hurt differently.

**A model doing script work** is slow, expensive, and subtly different every run — and you
cannot write a test against it. Counting is not a judgment call and should not be priced like
one.

**A script doing model work** is worse, because it fails silently. `extract-scout` used to
hardcode the sentence *"these break at runtime, in production, not at boot"* onto an entire
category of finding. On a real repo that sentence got attached to eight `class_name:` options,
for which it is simply false — a judgment about evidence, frozen into the one layer that cannot
revise it, and passed downstream to a model instructed to trust its tools.

The practical consequence: **your script should emit structured data, not prose.** Counts,
citations, kinds. The moment it starts emitting sentences, it has taken a job it cannot do well.
Let the model write the sentence, from the data, in front of the actual code.

---

## 3 · Write the integrity rules before the first report

Write these into the skill *before* you have seen output you like. Afterwards you will be tuning
a report you already believe.

Mine are two sentences, and they are the actual deliverable of the whole plugin:

> Every claim carries a `file:line`. Everything the analysis did not examine gets named as
> unexamined.

For flag-sweep the same two rules land as: every flag called dead carries the last `file:line`
that referenced it and the date; every flag the scan could not classify is *listed as
unclassified*, never quietly dropped.

Two things that make this harder than it sounds.

**The rule that governs the model must also govern the tools the model trusts.** `extract-scout`
told its skill "never invent a citation" — correct, well-placed, and pointed at the wrong layer.
Underneath it, the indexer was emitting `app/models/account.rb:53 → ActiveUser` for a constant
that does not exist. A precise line number pointing at nothing is exactly the failure the rule
exists to prevent, arriving through the door nobody guarded. A tool that returns confident
garbage launders it through a model that was told to trust tool output.

**Name what you did not look at, in the report itself.** Not in the docs — in the output, every
time. `extract-scout` prints four things it does not model, including schema foreign keys, which
are frequently the deciding factor. That clause is what stopped one engagement reaching a
confident wrong answer. Absence of a finding is not evidence of absence, and the only place that
sentence does any work is on the page the reader is already holding.

---

## 4 · Build a corpus before you trust it

Your unit tests will be green and your tool will be wrong. This is not a knock on your tests. A
synthetic fixture can only contain the cases somebody already thought of, and the defects that
matter are all the other ones.

`extract-scout` had a green suite and six live defects sitting under it. Every one of them
passed the whole suite.

The move that generalizes is this: **find the signature your failure leaves behind, and measure
it with no labelled data at all.**

- For a parser: a misparse fabricates a name, and a fabricated name resolves to nothing.
  Resolution rate is measurable on any repo, unlabelled, and it read **84.7% while every test
  was green.**
- For flag-sweep: a flag that exists in the provider's dashboard and appears *nowhere* in the
  codebase is either genuinely dead or a parse miss. If that number is 8%, you are looking at
  flag debt. If it is 40%, you are looking at your own bug.

Then pin two or three **real repos** and record baselines against them. Not fixtures — real
ones, at fixed refs, hand-checked once so the number means something. Adding three real Rails
apps to `extract-scout` produced nine defects in an afternoon, none of which any unit test could
have found.

The one that taught the most was the repo nothing had been tuned against, which passed on first
contact. That is the only evidence in the whole project that the fixes generalised rather than
overfit. Keep one repo you never tune against.

---

## 5 · Ship the hook last, and make it silent

A `PostToolUse` hook is the piece that keeps working after the audit is a stale document. It is
also the piece most likely to get your plugin uninstalled, so build it once the analysis is
trustworthy and not before.

The failure mode is not missed warnings. It is noise.

`extract-scout`'s skill instructed the scout to record every domain it resolved into
`domains.json`. On a 34-model app it dutifully wrote 34 "domains" — and every ordinary
`belongs_to` in the application became a boundary violation. Claude followed the instruction
correctly. The instruction was wrong: that file was doing two jobs, *what I measured* and *what
I want defended*, and only the second is a reason to interrupt somebody's edit.

Three rules that came out of that:

1. **Separate measurement from enforcement**, explicitly, in the data. Measurement is cheap and
   broad. Enforcement is a decision and should be narrow. Default to off.
2. **Resolve every ambiguous case to silence**, and write the silence down as a table. Each row
   is a test. Silence is a contract, not a preference.
3. **Build the self-test in the same commit.** Silence being the contract means a broken hook and
   a quiet one are indistinguishable — the blanket `rescue` that stops your bug from breaking
   somebody's tools also exits 0 on a crash. Have the hook construct its own payload and confirm
   it still fires. A shell mangling `\n` inside a JSON string once produced a confident,
   completely inverted conclusion about whether the hook worked at all.

---

## What to expect from Claude Code while you build this

The specific ways it goes wrong are consistent enough to plan around.

**It will follow a wrong instruction correctly.** This is the one that cost the most. When output
is bad, check the instruction before you check the model — the 34-domain disaster was a skill
bug wearing a model bug's clothes.

**It will hand you a confident measurement that cannot be true.** A latency table came back with
the *cheap* path slower than the expensive one. That is not a finding, it is noise wearing a
table. Re-measure anything physically impossible, at a sample size you choose, before you write
it down.

**It will write the skill to match the code it just wrote.** Write the skill first. Skills are
where the discipline lives, and a skill reverse-engineered from an implementation just describes
the implementation.

**Ask it, routinely, to name what it did not check.** It is good at this when asked and never
volunteers it.

---

## Checklist

- [ ] The manual answer's specific wrongness is one sentence you can say out loud
- [ ] `description` is written in your colleagues' words, not yours
- [ ] Every deterministic step is in a script; the script emits data, not prose
- [ ] Every judgment step is an agent, and gets the code in front of it
- [ ] The integrity rules are in the skill, and they bind the tools too
- [ ] The report names what it did not examine
- [ ] There is a measurement of correctness that needs no labelled data
- [ ] At least one real repo you never tune against
- [ ] The hook is off by default, silent when ambiguous, and self-tests

## Where to read the worked version

| | |
|---|---|
| The script/agent split, argued | [`../README.md`](../README.md) § Why a plugin |
| Integrity rules in place | [`../skills/extract-scout/SKILL.md`](../skills/extract-scout/SKILL.md) |
| What a corpus found | [`postmortem-docuseal-sweep.md`](postmortem-docuseal-sweep.md) |
| Decisions and where they would be wrong | [`scope-decisions.md`](scope-decisions.md) |
| What is still unresolved | [`open-questions.md`](open-questions.md) |
