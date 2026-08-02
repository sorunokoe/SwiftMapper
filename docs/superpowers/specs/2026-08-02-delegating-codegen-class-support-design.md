# SwiftMapper: Delegating Codegen, Auto-Detected Canonical Init, Class Support

## Status

Approved by assumption. The user asked three connected questions ("do we
really need `@MapperCanonical`?", "support class as well", "lift as many
limitations as possible") and was unavailable to answer follow-up scoping
questions. Per the `brainstorming` skill's guidance for this situation, this
spec proceeds on reasoned, validated engineering decisions rather than
guesses — every non-obvious decision below was checked against a real
compiled prototype (not just reasoned about), and is flagged as an
**Assumption** for the user to confirm or override. See
[Investigation](#investigation-empirically-validated) for the prototypes
that grounded these decisions.

## Problem

Three requests, all rooted in the same underlying codegen decision:

1. **`@MapperCanonical` friction.** Today, any type with 2+ initializers
   must have exactly one marked `@MapperCanonical`, even in the flagship
   documented case (a `Decodable`-conforming struct) where it's actually
   unambiguous which initializer is "the real one" — no other initializer
   even has a parameter list resembling the stored properties. The marker
   is pure ceremony in that case.
2. **No class support.** `@Mapper` only accepts a `struct`. Nothing about
   the DSL itself (labeled `Boxed<T>` closures, one slot per field) is
   struct-specific — the restriction is purely a codegen artifact (see
   below).
3. **Two known limitations that both look removable, not just
   documentable.** The README currently *documents* two compiler
   interactions rather than *fixing* them: a stored `let` property with an
   in-place default value can never compile once `@Mapper` is attached, and
   a struct with a hand-written `==`/`<`/`hash(into:)` alongside
   `Equatable`/`Hashable`/`Comparable` can trigger a real Swift compiler bug
   (swiftlang/swift#70087).

## Investigation (empirically validated)

Both the class-support blocker and both known limitations trace back to the
**same two codegen decisions** made when `@Mapper` was first built. Fixing
those two decisions turns out to resolve all three requests at once. Each
claim below was checked against a real, compiled Swift program (not just
reasoned about) before being written down here.

### 1. `self = creation(...)` is the blocker for classes and for the default-value limitation

Today's generated builder init assembles a full value via the canonical
initializer inside the result-builder's `buildBlock`, then does a
whole-`self` reassignment:

```swift
init(@FooBuilder _ creation: (...) -> Self) {
    self = creation(...)
}
```

`self = ...` whole-value reassignment:
- **Cannot appear in a class initializer at all** — Swift doesn't allow
  rebinding `self` to another instance in a class's `init`. This is the
  actual reason `@Mapper` can't support classes today; it isn't about the
  DSL, it's this one codegen line.
- **Is exactly what triggers** the "immutable value 'self.id' may only be
  initialized once" error for a stored `let` property with an in-place
  default value — verified by hand-compiling both shapes:
  - `self = creation()` against a struct with `let id: UUID = .init()`
    fails with that exact error.
  - The *same* struct, given a builder init that instead **delegates**
    (`self.init(value: creation())`), compiles and runs cleanly. No
    change to the struct itself — only to how the generated init hands
    values off.

The fix: change the generated init to **delegate** to the canonical
initializer instead of reassigning `self`:

```swift
// struct
init(@FooBuilder _ creation: (...) -> (FieldType1, FieldType2)) {
    let (field1, field2) = creation(...)
    self.init(field1: field1, field2: field2)
}

// class
convenience init(@FooBuilder _ creation: (...) -> (FieldType1, FieldType2)) {
    let (field1, field2) = creation(...)
    self.init(field1: field1, field2: field2)
}
```

This requires `buildBlock` to change from *constructing the full type* to
*aggregating the raw field values into a tuple* (for a single field, the
bare value itself, since Swift has no one-element tuples):

```swift
// before
static func buildBlock(_ id: String, _ name: String) -> Foo {
    Foo(id: id, name: name)
}

// after
static func buildBlock(_ id: String, _ name: String) -> (String, String) {
    (id, name)
}
```

Verified this doesn't break branching: `buildBlock<Component>`,
`buildEither<Component>(first:)`/`(second:)` are already fully generic and
pass a tuple `Component` through exactly as they would any other type — a
hand-compiled prototype with `if`/`else` branching inside the closure,
producing a tuple, worked identically to today's behavior.

Verified end-to-end with a real compiled program covering: a struct with a
default-valued `let` property (previously guaranteed to fail, now compiles
and runs), and a class using `convenience init` the same way, both driven
through hand-written result-builder scaffolding mirroring exactly what
`@Mapper` would generate.

### 2. `names: arbitrary` is the actual cause of the Equatable/Hashable/Comparable bug — not just correlated with it

The README already correctly diagnoses the root cause: `@Mapper` declares
`@attached(member, names: arbitrary)` because the generated nested
result-builder enum is named `<Type>Builder` — a name that depends on the
attached type, which isn't expressible via Swift macros' fixed
`named(...)` name list. `arbitrary` tells the compiler "this macro might
generate any name at all," which is what makes the compiler consider that
`@Mapper` might be generating `==`/`hash(into:)`/`<` too, conflicting with
a hand-written witness.

**This was verified to be fixable, not just explainable.** The nested
builder enum's name is never spelled out by a consumer anywhere (confirmed
by searching the README and every test — it only ever appears as
`@<Type>Builder` decorating the closure parameter, never written by a
caller). So it can be changed from `<Type>Builder` to a fixed,
type-independent nested name (`Builder`, i.e. `Foo.Builder`), which lets
the macro declare its exact member set instead of `arbitrary`:

```swift
@attached(member, names: named(init), named(Builder))
```

This was verified against a real, hand-modified build of this repository
(a disposable git worktree, discarded after the experiment): the exact
struct shape that reproduces swiftlang/swift#70087 today (a struct
conforming to `Equatable` with a hand-written `==` and a non-Equatable
stored field) was compiled and run successfully — not just silenced with a
warning, the compiler error is gone entirely, because the compiler now
knows precisely which members `@Mapper` can introduce.

**New, narrow edge case this introduces:** because the nested type's name
is now fixed (`Builder`) instead of derived from the attached type's own
name, a type that already declares its own nested member literally named
`Builder` would collide. This was structurally impossible before (the old
name was always type-specific) and needs its own diagnostic (see
[Diagnostics changes](#4-diagnostics-changes)).

## Design

### 1. Codegen: delegate, don't reassign

Both `struct` and `class` targets generate an initializer that delegates
to the canonical initializer, instead of reassigning `self`:

- **Struct:** an ordinary `init(...)` that calls `self.init(<labels>:
  <values>)`.
- **Class:** a `convenience init(...)` that calls `self.init(<labels>:
  <values>)`.

`buildBlock` changes to aggregate raw field values (a tuple for 2+ fields,
the bare value for exactly 1 field) instead of constructing the type.
`buildBlock<Component>`, `buildEither<Component>(first:)`/`(second:)` are
unaffected (already fully generic).

**Assumption:** this is purely an internal codegen change. The public call
site (`Foo { Field1, Field2 in ... }`) is identical before and after; no
existing passing test's *behavior* should change, only the generated
source shape asserted by macro-expansion tests.

### 2. Class support

`@Mapper` accepts a `ClassDeclSyntax` in addition to `StructDeclSyntax`.
The "canonical initializer" concept is identical for both: one designated
initializer whose parameter labels define the mapped fields. Class-specific
notes:

- The generated init is always `convenience`, delegating to the class's
  own designated (canonical) initializer — `@Mapper` never generates a
  *designated* initializer for a class, so it never needs to know about
  `super.init(...)` at all. This mirrors the existing struct model exactly:
  a stored property the canonical initializer sets itself (not exposed as
  a builder field) is already untouched by `@Mapper` today (e.g. the
  README's `ProfileHeaderData.id` example); a superclass's stored
  properties, set via the canonical initializer's own `super.init(...)`
  call, are just another instance of "a property the canonical initializer
  handles itself."
- `open`/non-`final` classes work the same as `final` ones — adding a
  `convenience init` doesn't change subclassing semantics, so there's
  nothing to special-case.
- The `notAStruct` diagnostic is renamed (message and case) to describe
  both valid targets, e.g. "`@Mapper` can only be attached to a struct or
  class."

**Assumption:** `@Mapper` generating a class's *designated* initializer
(rather than always a `convenience` one) is out of scope — that would
require the macro to understand and call the correct `super.init(...)`,
which is a materially different, larger feature than anything requested
here. If a consumer wants the generated init to be their class's *only*
initializer, they can still make their own canonical initializer
`private`/`fileprivate` and only expose the generated `convenience init`
publicly — already possible with the current access-modifier forwarding.

### 3. `@MapperCanonical` becomes an override, not a requirement

New resolution order, replacing today's "always require the marker for 2+
initializers" rule:

1. **Exactly one initializer** — used automatically (unchanged).
2. **2+ initializers, exactly one marked `@MapperCanonical`** — the marked
   one wins, regardless of shape (unchanged; existing marked code keeps
   working identically).
3. **2+ initializers, none marked, exactly one is "memberwise-shaped"**
   (its parameter labels are an exact set match — same names, any order —
   against the full set of the type's own stored properties) — that one is
   used automatically. This is the new behavior: no marker needed for the
   common case (e.g. a `Decodable`-conforming type whose `init(from:)`
   doesn't remotely resemble a memberwise init).
4. **2+ initializers, none marked, zero or 2+ are memberwise-shaped** —
   ambiguous; diagnose exactly as today (every initializer on the type,
   with a Fix-It suggesting `@MapperCanonical` on each).
5. **2+ initializers, 2+ marked `@MapperCanonical`** — unchanged, always an
   error.

**Assumption:** "exact set match of parameter labels against stored
property names" (not initializer body inspection, not requiring the same
order) is the right heuristic — consistent with how `@Mapper` already
treats an initializer's *signature*, never its body, as the source of
truth for the field list. Inspecting the body to verify each parameter is
actually assigned 1:1 would be far more fragile to write correctly as a
syntax-only check and isn't needed to resolve the stated friction.

A deliberate consequence of requiring a match against *all* stored
properties (rather than a subset): a type whose canonical initializer
intentionally excludes a self-managed property — the same pattern the
README already documents for `ProfileHeaderData.id`, set via `.init()` in
the initializer body rather than taken as a parameter — will **not**
auto-detect if that type also has more than one initializer, since the
canonical one no longer matches the *full* stored-property set.
`@MapperCanonical` is still required in that combined case (self-managed
property *and* multiple initializers together). This is intentional, not
an oversight: a *subset* match (rather than exact) was considered and
rejected, because it would make a genuinely ambiguous, common shape look
falsely unambiguous — e.g. a full memberwise init `init(id:name:email:)`
alongside a convenience init `init(name:)` that fills in defaults for the
rest would have both candidates "subset-match," picking one arbitrarily
where today's behavior correctly asks the user to disambiguate.

### 4. Diagnostics changes

- **Removed:** `defaultValuedStoredProperty` (error) and its detection —
  the limitation it exists to catch no longer occurs.
- **Removed:** `likelyEquatableConformanceConflict` (warning) and its
  detection — the bug it warns about no longer occurs.
- **Renamed:** `notAStruct` → describes struct-or-class.
- **Added:** a diagnostic for a type that already declares its own member
  named `Builder`, pointing at that member with a message explaining
  `@Mapper` needs that name for its generated result-builder enum (rename
  the existing member, or don't apply `@Mapper` to this type).
- **Unchanged in spirit, updated in wording:** `multipleInitializers` now
  fires only for the genuinely ambiguous cases above (zero or 2+
  memberwise-shaped candidates), still diagnosing every initializer on the
  type with the same Fix-It — it does not narrow the diagnosed set to just
  the memberwise-shaped candidates.

### Non-goals (unchanged from prior workstreams, plus new ones for this change)

- Enum support remains a separate, already-spec'd, deferred workstream —
  untouched by this change.
- No change to the variadic-parameter or unlabeled-parameter requirements
  — these are the DSL's actual model (one labeled slot per field), not
  incidental compiler limitations, so there's nothing to "lift."
- `@Mapper` generating a class's *designated* initializer, or doing
  anything with a superclass's initializer — out of scope (see
  Assumption in [Class support](#2-class-support)).
- Mapping a superclass's stored properties as builder fields directly —
  same non-goal as a struct's own non-field stored properties today.

## Impact on existing surface

- **README:** "Known limitations" section is removed (or reduced to a
  single short note about the new `Builder`-name-collision diagnostic, if
  that's judged worth keeping visible). "Multiple initializers" section
  rewritten: auto-detection is the primary path, `@MapperCanonical` is the
  override/tie-break path. New examples/mentions for class support
  throughout (Usage, Requirements).
- **`Mapper.swift` doc comments:** updated throughout to say "struct or
  class" instead of "struct," and to describe auto-detection.
- **Tests:** every existing macro-expansion test asserting the
  `self = creation(...)` shape needs updating to the new delegating shape
  and tuple-returning `buildBlock`. `defaultValuedStoredProperty` and
  `likelyEquatableConformanceConflict` tests are removed (their scenarios
  no longer diagnose anything — a passing-compilation integration test
  replaces each, proving the limitation is gone). New tests: class support
  (expansion + integration, including a default-valued stored property on
  a class), auto-detection without a marker, the rare ambiguous-tie case,
  and the new `Builder`-name-collision diagnostic.

## Delivery approach

This continues directly on the still-open `feature/greatest-swiftmapper`
branch (PR #1), since it revises `@MapperCanonical` and the core codegen
introduced in that same, not-yet-merged PR — starting a second branch off
`main` would mean reimplementing that code from scratch and would split
review across two PRs that partially contradict each other. Delivered as a
**new commit** on that branch (not amended into the existing one, since
that commit already went through its own review round) with its own
build/test verification, pushed to update PR #1.
