# SwiftMapper: Enum Support (`@Mapper` on `enum`)

## Status

Design-only. Per the broader "make SwiftMapper the greatest composable
mapper" plan, this is the highest-risk, most novel workstream of the six
identified, and is deliberately sequenced to stop at a spec — no
implementation should start until this design (and in particular the two
"Needs prototyping before implementation" items below) is reviewed.

## Problem

`@Mapper` currently only attaches to a `struct`, because a struct's single
canonical initializer gives the macro exactly one thing to key off: a fixed,
ordered parameter list that becomes the generated builder's fields. An
`enum` has no equivalent single shape — each case can carry a different
number, order, and type of associated values (or none at all), so there is
no one "canonical initializer" to read.

Enums are still a natural target for the same DSL, though. A very common
mapping shape is exactly the kind of `switch` already shown working inside a
struct's builder closure (see the README's `Branching` section) but where
one or more branches construct an enum case that itself carries a payload
worth mapping field-by-field instead of as one flat expression:

```swift
enum ProfileState: Equatable {
    case idle
    case loading
    case loaded(profile: Profile, fullname: String)
    case failed(message: String)
}
```

Today, populating `.loaded` still means a single flat expression
(`.loaded(profile: ..., fullname: ...)`) or building the payload into local
variables first — neither gets the labeled, compile-time-checked builder
closure struct fields already get.

## Vepol model

Modeled at the conflict zone (per the TRIZ workflow this plan followed):

- **S1 (tool):** the `@Mapper` macro's compile-time code-generation field.
- **Field:** syntactic transformation of a declaration's "shape" (labels,
  types, order) into a matching builder initializer + result-builder enum.
- **S2 (object):** for structs, the single canonical initializer's parameter
  list. For enums, there is no single S2 of that shape — instead there are
  *N* independent shapes, one per case, some empty (no associated values).

This is an **incomplete vepol**: the existing field (one fixed template,
one S2) doesn't have a matching S2 for enums. The fix isn't to force enums
into the struct-shaped field — it's to complete the vepol with a *new*,
per-case S2 that the same underlying field (labeled `Boxed<T>` closure +
result-builder enum) can still act on.

## Recommended approach: per-case builder factories

Instead of one builder initializer for the whole type (struct model), the
macro generates one **static factory function** per case that has at least
one associated value, each with its own nested `@resultBuilder` enum — the
same `Boxed<T>` mechanism, scoped to that case instead of to the whole type:

```swift
extension ProfileState {
    static func loaded(
        @LoadedBuilder
        _ creation: (
            _ Profile: Boxed<Profile>,
            _ Fullname: Boxed<String>
        ) -> (Profile, String)
    ) -> Self {
        let (profile, fullname) = creation(.init(), .init())
        return .loaded(profile: profile, fullname: fullname)
    }

    @resultBuilder
    enum LoadedBuilder {
        static func buildBlock(_ profile: Profile, _ fullname: String) -> (Profile, String) {
            (profile, fullname)
        }
        // ...buildBlock<Component>/buildEither, same as the struct case
    }
}
```

letting call sites write:

```swift
let state: ProfileState = domain.isLoading
    ? .loading
    : .loaded {
        Profile { domain.profile }
        Fullname { domain.fullName }
    }
```

Cases with **no** associated values (`idle`, `loading`) need no generated
code at all — `.idle` already works with zero machinery, so the macro simply
skips them. This keeps the "insufficient vepol" fix scoped to exactly the
cases that need it, rather than generating unused API surface (matches the
existing library's ethos: only generate what a case's own shape calls for,
the same way a struct's own initializer — not the macro — decides the
field list).

### Why not a single, struct-like discriminator initializer

An alternative considered: one builder closure for the whole enum, with a
labeled `Boxed<T>` slot *per case* that returns `Self` when invoked (mirroring
the struct model's single builder closure exactly). Rejected: cases have
incompatible arities and types, so the single generated `buildBlock` the
struct model relies on (one fixed signature) has no equivalent — each case
would need its own `buildBlock` overload with a *different* return
construction, which is exactly what the per-case factory approach above
already gives you, without inventing a new whole-enum closure shape on top.

## Open design questions — needs resolution before implementation

1. **Case-name collision with the compiler-synthesized case constructor
   (needs prototyping).** A case like `case loaded(profile: Profile, fullname: String)`
   already gives you a callable `ProfileState.loaded(profile:fullname:)`.
   The proposed `static func loaded(_ creation: (...) -> (...)) -> Self`
   shares the same base name (`loaded`) but a different parameter shape
   (a single trailing closure vs. two labeled arguments). Swift can usually
   disambiguate overloads by argument labels/shape, but this needs an actual
   compiler check — including at a call site using trailing-closure syntax,
   where overload resolution rules are more subtle — before committing to
   this name. **Do not start implementation until this is verified with a
   small hand-written (non-macro) prototype.**
2. **Unlabeled associated values.** `case failed(String)` is idiomatic Swift
   and has no label to build a `Boxed<T>` slot name from — unlike a struct's
   initializer, where `@Mapper` already requires every parameter to have an
   explicit label (see the `unlabeledParameter` diagnostic). Two options:
   require every associated value used by `@Mapper` to be labeled (consistent
   with the struct rule, but a bigger ergonomics ask since unlabeled
   associated values are common), or fall back to the case name itself for a
   *single* unlabeled value and diagnose an error for two or more unlabeled
   values on the same case (ambiguous — no way to derive distinct slot
   names). Needs a decision, not just an implementation default.
3. **Which cases get a factory.** Cases with zero associated values: skip, as
   above. Cases with exactly one *labeled* associated value: still worth
   generating (even though the payoff over `.failed(message: ...)` directly
   is small) for consistency, or skip as unnecessary generated surface? Lean
   toward generating for consistency, but flag as a call to make explicitly
   rather than assume.
4. **Generic enums.** Should follow the same reasoning already validated for
   generic structs (member-macro-generated members are lexically nested, so
   generic parameters should already be in scope) — but needs its own
   expansion + integration test pass, the same way generic struct support
   was verified rather than assumed, before being documented as supported.
5. **`indirect` cases/enums.** Not yet considered; needs its own check for
   whether `indirect` changes anything about the generated factory (it
   shouldn't, since the factory just calls the existing case constructor,
   but this needs verifying, not assuming).

## Non-goals (carried over from the struct-side non-goals)

- **Not a pattern-matching/extraction helper.** `@Mapper` on an enum only
  helps *construct* a case's payload with a labeled DSL — it does not help
  destructure an existing enum value, and does not add `switch`-replacement
  machinery. Consistent with the existing "not a validation framework"
  non-goal.
- **Not a way to make case selection itself declarative.** Which case to
  construct is still an ordinary Swift `if`/`switch`/ternary at the call
  site (as in the `ProfileState` example above) — `@Mapper` only takes over
  once a specific case's payload needs building.

## Suggested next steps (not part of this plan's scope)

1. Hand-write (no macro) the two `ProfileState` examples above and confirm
   in a scratch package that the `static func loaded(...)` factory and the
   compiler-synthesized `.loaded(profile:fullname:)` constructor don't
   collide or shadow each other at realistic call sites, including
   trailing-closure syntax and type-inferred contexts (`let x: ProfileState = .loaded { ... }`).
2. Resolve the unlabeled-associated-value question (open question 2) with
   the library's maintainer before writing the diagnostic rules for it.
3. Only after 1 and 2: write an implementation plan (mirroring the structure
   of `docs/superpowers/plans/2026-07-31-branching-and-diagnostics.md`) with
   its own task-by-task breakdown and test-first steps.
