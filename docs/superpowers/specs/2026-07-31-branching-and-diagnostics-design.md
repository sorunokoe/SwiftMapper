# SwiftMapper: Branching Support + Diagnostic Improvements

## Status

Approved by assumption — the user requested this change but was unavailable to
answer scoping questions. Per their explicit ask ("implement branching and
other useful and necessary features... make sure this library shows correct
and useful error messages"), this spec keeps scope to exactly the two things
requested — branching and diagnostics — and deliberately excludes several
adjacent features (see [Non-goals](#non-goals)) to keep the library
"lightweight and simple," per the user's own framing. These exclusions are
assumptions, not confirmed decisions, and are flagged in the final summary for
the user to revisit if wrong.

## Problem

The generated `@<Type>Builder` result-builder enum (produced by the `@Mapper`
macro) currently implements only a single, fixed-arity `buildBlock(_:_:...)`
overload — one non-optional parameter per canonical-initializer field, in
order. Swift's result-builder transform requires a builder to implement
`buildEither(first:)` / `buildEither(second:)` for `if`/`else` and `switch`
statements to appear directly inside an annotated closure, and
`buildOptional(_:)` for a plain `if` (no `else`). None of these are
implemented, so branching cannot appear directly inside the labeled builder
closure today — the README documents this as a limitation and tells users to
hoist branching into a `switch` **expression** computed outside the closure.

That workaround is correct but goes against the library's whole premise
(composable, DSL-like mapping code) — the moment a field's value depends on a
condition, the user is forced back out of the DSL. This change removes that
limitation.

Separately, the user asked that error messages the library surfaces to
consumers (compile-time diagnostics from the macro) be reviewed for
correctness and usefulness. One concrete defect exists today:
`multipleInitializers` is diagnosed at the position of the *first* (kept)
initializer rather than the extra one(s) causing the problem — exactly
backwards from what's useful.

## Goals

1. Let `if`/`else` and `switch` appear directly inside a `@<Type>Builder`
   closure, each branch producing a field's value in place.
2. Let a plain `if` (no `else`) work for fields whose canonical type is
   already `Optional<X>`.
3. Fix `multipleInitializers` to diagnose at each *extra* initializer
   (skipping the first, kept one), so the compiler error points exactly at
   what to remove.
4. Add a Fix-It to `unlabeledParameter` that offers replacing the `_` label
   with the parameter's existing internal name, since that's almost always
   the label the user actually wants.
5. Pass over all six existing diagnostic messages for wording clarity /
   actionability; tighten any that are vague.
6. Update the README: remove the "note on branching" limitation section,
   replace with direct examples of `if`/`else`, `switch`, and optional-`if`
   working inside the builder closure.
7. Add test coverage for all of the above (macro-expansion + integration).

## Non-goals

These are reasonable extensions to a "mapper DSL" library in the abstract,
but out of scope for *this* change because they weren't requested and each
adds real surface area/complexity the user asked to avoid ("yet make it
lightweight and simple"):

- **`for`-loop / array-field building (`buildArray`).** Doesn't fit the
  current one-slot-per-field model without a design of its own (which field
  would a loop populate, and how would arity stay fixed?).
- **Treating default-valued canonical-init parameters as optional builder
  fields.** Changes the "every field must be supplied" guarantee the README
  currently promises as a *feature*, not a gap.
- **Enum or generic-struct support as `@Mapper` targets.** Meaningfully larger
  macro-implementation scope (different member layout, generic parameter
  forwarding) than a diagnostics/branching pass.
- **`if #available` / `buildLimitedAvailability`.** Trivial to add
  mechanically, but no evidence it's needed yet (GolfApp's iOS target already
  has a fixed minimum deployment target); adding unused API surface conflicts
  with "lightweight."

If any of these turn out to be wanted, they're each small, independent
follow-ups — intentionally not bundled here so this change stays reviewable
and focused.

## Design

### 1. Generic `buildEither` / `buildOptional` on the generated builder enum

Add three generic, identity-passthrough static functions to the
`builderEnum` template `MapperMacro.swift` emits, alongside the existing
`buildBlock`:

```swift
public static func buildEither<Component>(first component: Component) -> Component {
    component
}

public static func buildEither<Component>(second component: Component) -> Component {
    component
}

public static func buildOptional<Component>(_ component: Component?) -> Component? {
    component
}
```

These carry no knowledge of which field they're being used for — Swift's
result-builder transform applies them to a single *statement* inside the
closure (e.g. one field's `if`/`else`), independently of the fixed-arity
`buildBlock` call that combines the block's top-level statements. Because
each field slot in `buildBlock` has its own concrete type, generic inference
binds `Component` to that field's type for that particular branch — there's
no cross-field ambiguity.

Semantics fall directly out of Swift's own result-builder rules, so no new
custom validation is needed:
- `if`/`else` or `switch` (all cases): both/all branches must independently
  produce a value of the field's exact declared type. If they don't, the
  user gets the ordinary Swift type-checker error at the mismatched branch
  — not a SwiftMapper-specific error.
- Plain `if` (no `else`): produces `Component?`. This only type-checks
  against a field whose declared type is already `Optional<X>` (`Component`
  binds to `X`, giving `X?` — which matches). For a non-optional field, the
  compiler correctly rejects it, same as writing `let x: String = ifCond ?
  "a" : nil` would be rejected — expected, not a regression.

Access level mirrors the existing `accessModifier` used for `buildBlock`
(the generated enum is `public` iff the struct is `public`).

### 2. `multipleInitializers` — diagnose the actual extra initializer(s)

Currently:
```swift
guard initializers.count == 1 else {
    context.diagnose(MapperDiagnostic.multipleInitializers.diagnose(at: canonicalInit))
    return []
}
```
`canonicalInit` is `initializers.first` — the diagnostic points at the
initializer that would have been kept, not the one(s) causing the problem.

New behavior: emit one diagnostic per initializer *after* the first,
attached at that initializer's own node:
```swift
guard initializers.count == 1 else {
    for extraInit in initializers.dropFirst() {
        context.diagnose(MapperDiagnostic.multipleInitializers.diagnose(at: extraInit))
    }
    return []
}
```
This means a struct with 3 initializers gets 2 diagnostics, each at the
offending declaration — matching how Xcode/SwiftPM surface multiple
independent errors for multiple independent problems.

### 3. `unlabeledParameter` — add a Fix-It

For a parameter written as `_ profile: String` (no external label), the
overwhelmingly likely intent is that the internal name (`profile`) should
also be the external label — i.e. `profile profile: String` (or, if no
internal name is present either — e.g. `_: String` — no mechanical fix is
possible, so no Fix-It is offered in that fallback case).

`SwiftDiagnostics`' `FixIt` API supports a `replace(childAt:with:)` /
node-replacement change; since our diagnostic already carries the
`FunctionParameterSyntax` node, the fix rewrites the parameter's
`firstName` token from `_` to the existing `secondName` token's text
(cloning its trivia), leaving everything else (type, default value)
untouched.

### 4. Diagnostic message wording pass

Reviewed all six messages for actionability. Five read fine as-is;
`unlabeledParameter`'s message is tightened to explicitly point at the fix
now offered:

- Before: *"@Mapper requires every initializer parameter to have a label
  (no '_' parameters)"*
- After: *"@Mapper requires every initializer parameter to have an explicit
  label; use the parameter's internal name as the label instead of '_'"*

No other message copy changes — `notAStruct`, `missingInitializer`,
`unsupportedParameter`, and `noFields` are already clear and actionable.

### 5. README updates

- Delete the "A note on branching" section's *limitation* framing.
- Replace with a short section showing `if`/`else`, `switch`, and
  optional-field plain-`if` working directly inside the builder closure,
  using the same `Handicap`/`trend` example already in the README so the
  diff reads as "this now works," not a new unrelated example.

### 6. Tests

**Macro-expansion tests** (`MapperMacroExpansionTests.swift`):
- Assert the expanded `builderEnum` now includes the three generic
  `buildEither`/`buildOptional` functions (extend the existing
  `testExpandsBuilderInitAndResultBuilder` expected output).
- New test: struct with 3 initializers emits 2 diagnostics, at the 2nd and
  3rd initializer's own source locations (not the 1st).
- New test: `unlabeledParameter` diagnostic now includes a `FixIt` in its
  `DiagnosticSpec` (fixIts:) replacing `_` with the internal name.

**Integration tests** (`MapperIntegrationTests.swift`):
- New test: a mapper struct with a field built via `if`/`else` inside the
  builder closure produces the expected value for both branches.
- New test: same struct with a `switch` (3+ cases) inside the builder
  closure.
- New test: a struct with one `Optional<String>` field, built via a plain
  `if` (no `else`) inside the closure, for both the "condition true" and
  "condition false" (nil) cases.

## Verification plan

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift build
swift test
```
All existing + new tests must pass. No change to `Package.swift` is needed
for this work (no new dependencies).

After merging in `SwiftMapper`, no changes are required in the `nord`
(GolfApp) consumer repo for this to take effect — `Foundation/Core` already
depends on `SwiftMapper` via `from: "1.0.0"`; a new `SwiftMapper` release
(e.g. `1.1.0`) will need to be tagged for GolfApp to pick it up via
`swift package update`, since `from: "1.0.0"` resolves to the latest
1.x — no manifest edit needed there, just a version bump/tag on this side.
