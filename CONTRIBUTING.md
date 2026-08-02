# Contributing to SwiftMapper

Thanks for considering a contribution. SwiftMapper stays useful by staying
small and deliberate — please read this before opening a PR.

## Before writing code

SwiftMapper's README lists explicit **non-goals** (no runtime combinator
layer, no validation/error-accumulation framework). Any change that grows
the library's surface area — new macro behavior, new diagnostics, new
public API — should start as a short written plan, not a PR, so scope and
tradeoffs can be discussed before code is written.

This repository uses a lightweight plan/spec convention under
[`docs/superpowers/`](docs/superpowers):

- `docs/superpowers/plans/` — dated implementation plans (problem, goals,
  explicit non-goals, task breakdown).
- `docs/superpowers/specs/` — dated design specs for larger or riskier
  changes, written *before* an implementation plan when the design itself
  needs review first (see
  [`2026-08-02-enum-support-design.md`](docs/superpowers/specs/2026-08-02-enum-support-design.md)
  for an example of a spec-first, implementation-later change).

For a small, self-contained fix (a typo, a missing test, a diagnostic
wording tweak), a plan isn't necessary — just open a PR.

## Making a change

1. Open a plan (or spec, for larger changes) under `docs/superpowers/` if the
   change adds capability rather than just fixing something existing.
2. State non-goals explicitly. "Everything the code could plausibly do" is
   not scope — write down what you're deliberately *not* doing and why.
3. Add tests before/alongside the change:
   - Macro-expansion tests in `Tests/SwiftMapperTests/MapperMacroExpansionTests.swift`
     assert the exact generated code (and diagnostics) for a given input.
   - Integration tests in `Tests/SwiftMapperTests/MapperIntegrationTests.swift`
     compile a real `@Mapper`-annotated type and assert on its runtime
     behavior.
4. Update `README.md` for anything user-facing (new capability, new
   diagnostic, changed requirement).
5. Run the full check locally before opening a PR:

   ```sh
   swift build
   swift test
   ```

## Code conventions

- Mapper field names should read as what the value *is*, not how it was
  obtained (prefer `Fullname { user.displayName }` over
  `FullnameFromDisplayName { user.displayName }`).
- Prefer an explicit `if`/`else` over `??`/optional-coalescing inside a
  builder closure when the two branches represent genuinely different
  mapping logic, not just a default value.
- Context/dependency parameters a mapping needs (e.g. a locale, a feature
  flag) should be threaded explicitly as parameters to the mapping function,
  not looked up ambiently/globally.

## Opening a PR

- One focused change per PR. If a plan covers several workstreams, prefer
  one PR per workstream over one large PR, unless the workstreams are only
  meaningful together.
- Do not merge your own PR without review, even if CI is green.
