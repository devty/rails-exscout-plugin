# docs

Field notes on `extract-scout`, written from real runs rather than from the source.

| Document | What it covers |
|---|---|
| [`postmortem-docuseal-sweep.md`](postmortem-docuseal-sweep.md) | The 34-model DocuSeal sweep: what held up, six cited defects (D1–D6) with reproduction steps, and ergonomic findings. |
| [`blind-spots.md`](blind-spots.md) | What the tool structurally does not model, split by whether `not_analyzed` discloses it. |
| [`open-questions.md`](open-questions.md) | Review questions — evaluation methodology, the agent/script split, hook signal-to-noise, product framing. |

## The short version

Run against [docuseal](https://github.com/docusealco/docuseal) at `004a22c1` (Rails 7, 304 files, 34
models), plugin at `dcd3dec`.

**Held up:** the magnitude/blocking split, inverse-pair separation (without it all five hub models
would have falsely printed `BLOCKED`), scoring on caller breadth rather than edge count, exact
boundary resolution 34/34, and the `not_analyzed` clause — which is what led to the finding that
actually answered the question.

**Did not:** six defects, D1–D6, all now fixed. The parser read only the first physical line of an
association macro; `through:` and polymorphic associations resolved to constants that do not exist
and were silently dropped; a namespace collapsed into one unit manufactured a cycle; every
capitalised string was treated as a constant; and `boundary_assoc` was hardcoded `major` so the
severity axis was pinned for 31 of 34 domains.

**Cumulative effect on the DocuSeal sweep:**

| | before | after |
|---|---|---|
| association refs recorded | 118 | **128** |
| refs naming a non-existent constant | 18 (15.3%) | **7**, all deliberate |
| `boundary_assocs` over 34 domains | 196 | **232** (+18%) |
| string refs recorded | 372 | **17** |
| string refs resolvable **and** genuine | ~64% | **100%** |
| `cycle_units` | 1 *(false positive)* | **0** |
| `max_severity` blocker / major / moderate | 1 / 31 / 1 | **5 / 10 / 18** |

Every domain now flagged `blocker` is blocked by a genuine polymorphic association. There is no known
false positive left in the sweep.

**Biggest gap:** the tool models the constant graph, and for a Rails→Node port the constant graph was
not the deciding factor. One part of that gap has since closed — the polymorphic coupling that became
§4 of the migration report was originally found by hand-reading models, and the tool now surfaces it
structurally at `blocker` severity. The rest of `blind-spots.md` is still open, and the runtime
surface (encryption, ActiveStorage, `serialize`, app-level defaults) is still unmodelled and still
undisclaimed.
