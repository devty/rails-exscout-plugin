# Changelog

Notable changes to `extract-scout`. Versions follow [semver](https://semver.org); while the
plugin is `0.x`, minor bumps may change behaviour.

## 0.2.0 — unreleased

### Changed behaviour you will notice

- **The `PostToolUse` hook no longer warns unless a boundary is marked `"enforce": true`.**
  `domains.json` was serving as both *"what I measured"* and *"what I want defended"*, and only
  the second is a reason to interrupt an edit. A per-model sweep records one entry per model, so
  following the skill correctly turned every ordinary `belongs_to` into a warning — the hook's
  first design constraint broken by using it as documented.

  A missing flag reads as `false`, so an existing `domains.json` goes quiet the moment this
  lands, and the hook falls back to namespace inference. **If you relied on those warnings, set
  `"enforce": true` on the boundaries you actually want defended.**

- **The verdict reports magnitude and blocking separately.** The score saturated every
  component, cycles included, so one true cycle scored 1.1 and printed *"Clean — extractable
  as-is"* directly above `[BLOCKER]`. The score is now magnitude only; `max_severity` carries
  blocking, and the headline reads `1.7/10 -- Clean, but BLOCKED`.

- **`lib/` is no longer assumed to be an autoload root.** Rails 7+ does not autoload it unless
  the app opts in, and a `lib/` that is not autoloaded usually holds gem monkey-patches.

### Added

- **Ambient infrastructure is set aside before counting.** A constant reached by 10+ units
  whose edges are 90%+ `mixin`/`superclass` is scaffolding, not coupling — reported under
  `AMBIENT` with the numbers that justified it, and excluded from seams and the score. It
  subsumes the hardcoded ubiquitous list and finds what that list missed. Breadth alone is
  deliberately not the rule: Mastodons widest-reach constant is `Account`, the god-model,
  and a breadth-only rule would delete the most important finding in the app. See
  [`docs/scope-decisions.md`](docs/scope-decisions.md).
- **`--format brief`** — the same findings as `--format json` with the per-file evidence map
  replaced by a tally and citations capped. ~64k tokens to ~10k on a large domain, for
  decisions that never needed the difference. The terminal report also caps its seam list,
  and says how many it hid and at what severity rather than truncating silently.
- **Seams order by severity tier, then size.** The README always promised "ordered by what
  blocks what, not by size"; scores had no saturation, so on ActivityPub one `moderate` seam
  outranked twenty-six blockers.

- `--summary`, `--all` and `--domains-from` rank a whole candidate set in one invocation and
  print the ordered table directly. `--all` doubles as a portfolio view over the repo.
- `--diagnose` reports constant-resolution rates per edge kind and exits non-zero when
  associations fall below a 90% floor, plus a second tripwire that needs no references at all:
  under Zeitwerk a booting app cannot declare a constant its path does not imply.
- `--target ruby-service | modular-monolith | other-language` changes seam weights, severities
  and remedies to match where the code is actually going. `other-language` leads with a caveat
  saying the static constant graph is probably not the deciding axis.
- `EXTRACT_SCOUT_HOOK=debug` names every hook exit path on stderr and surfaces exceptions the
  blanket rescue swallows. `check_cross_domain.rb --self-test` proves the hook can still fire.
- Reads the repo's own conventions instead of guessing at them: custom inflections from
  `config/initializers` and `engine.rb`, Packwerk `package.yml` packages, and engine monorepos
  marked by a `.gemspec`.
- `test/` — a suite where there was none, plus `test/corpus.rb` and four pinned real Rails apps
  with hand-checked resolution baselines.

### Fixed

Fifteen defects, all found by running the tool over real code rather than by reading it. Six
from a 34-model sweep of DocuSeal (D1–D6), nine more from Mastodon, Solidus and Chatwoot.

- `class_name:` was read only on the association macro's own physical line (**15.3% of all
  association edges** on DocuSeal), and was ignored entirely when set by an enclosing
  `with_options` block.
- `has_many :through` emitted only a guess at the far end, losing the join dependency.
- Polymorphic associations inferred constants that do not exist, making the hardest association
  type to extract invisible.
- A namespace collapsing into one unit manufactured cycles that were not there.
- Any capitalised string was treated as a constant — **96% of recorded string refs were noise**.
- `boundary_assoc` was hardcoded `major`, pinning severity for 31 of 34 domains.
- `app/serializers` macros were counted as ActiveRecord associations — 105 phantom edges on
  Mastodon, since `ActiveModel::Serializer` reuses `has_many` for a different purpose.
- Irregular plurals applied as whole words rather than suffixes
  (`preview_cards_statuses` → `PreviewCardsStatuse`).
- Engine monorepos resolved to **zero** autoload roots: Solidus indexed 1204 files and gave none
  of them a constant.
- Inflection rules declared in a gem's own initializers or inside `engine.rb` were not read.
- Constant assignments (`Foo = Struct.new(...)`) were not recorded as definitions, and
  `class ::Foo::Bar` was not recognised as a definition at all.
- `obj.extend Helpers` was classified as a mixin, inflating the shared-mixin seam with receiver
  calls that mix nothing in.

Measured association resolution: Mastodon 73% → 95%, Solidus 54% → 95%. Chatwoot passed at 97%
on first contact with no changes — the one corpus repo nothing was tuned against, and the only
real evidence here that these fixes generalise rather than overfit.

## 0.1.0

Initial release.
