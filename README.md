# SwiftMapper

A tiny Swift macro that turns a struct's own initializer into a composable,
type-safe "field builder" DSL — without a runtime combinator library, and
without hand-writing a `@resultBuilder` for every type you map into.

## The problem

Hand-written data mappers tend to collapse into one of two shapes:

1. **A flat initializer call** that's easy to get subtly wrong (arguments in
   the wrong order, a field silently left mapped to the wrong source field),
   and where every field's mapping logic is squeezed onto one line or hidden
   behind a private helper method.
2. **A generic `Mapper<Input, Output>` combinator library** (`.map`,
   `.pullback`, `.optional()`, ...) that solves the readability problem but
   introduces a whole runtime abstraction, its own debugging story, and a
   learning curve — often more machinery than the mapping logic it wraps.

SwiftMapper takes a third path: keep each field's mapping logic as a small,
labeled, ordinary closure, and let the compiler check that every field is
supplied, in the right shape, at compile time — with zero runtime cost.

```swift
@Mapper
public struct ProfileHeaderData: Equatable, Sendable {
    public let id: UUID
    public let profile: Avatar
    public let fullname: String
    public let nickname: String

    public init(profile: Avatar, fullname: String, nickname: String) {
        self.id = .init()
        self.profile = profile
        self.fullname = fullname
        self.nickname = nickname
    }
}
```

`@Mapper` reads that initializer and adds a labeled builder initializer, so a
mapper can write:

```swift
ProfileHeaderData { Profile, Fullname, Nickname in
    Profile { Avatar(url: domain.avatarURL) }
    Fullname { domain.fullName }
    Nickname { domain.playerName }
}
```

Each labeled slot (`Profile`, `Fullname`, `Nickname`) is just a plain closure
call — no combinators, no runtime tracing, nothing to import except
`SwiftMapper` itself. This is the same pattern proven by hand across several
mappers before being generalized here; see [How it works](#how-it-works) for
what the macro actually generates.

## Installation

Add SwiftMapper as a package dependency in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sorunokoe/SwiftMapper.git", from: "1.0.0"),
]
```

and add `SwiftMapper` to any target that needs it:

```swift
.target(
    name: "YourTarget",
    dependencies: ["SwiftMapper"]
)
```

## Usage

1. Write your struct exactly as you normally would, with a single explicit
   initializer that sets every field you want the builder to cover.
2. Attach `@Mapper` to the struct.
3. Call the struct's new builder initializer with one labeled closure per
   initializer parameter (Xcode autocompletes the labels from the
   initializer's own parameter names, capitalized).

```swift
import SwiftMapper

@Mapper
struct Address: Equatable {
    let street: String
    let city: String
    let postalCode: String

    init(street: String, city: String, postalCode: String) {
        self.street = street
        self.city = city
        self.postalCode = postalCode
    }
}

let address = Address { Street, City, PostalCode in
    Street { rawInput.line1 }
    City { rawInput.city.capitalized }
    PostalCode { rawInput.zip.trimmed() }
}
```

Structs that nest other `@Mapper` structs compose naturally — a nested
struct's own builder initializer can be called from inside an outer struct's
builder closure, the same way you'd construct it anywhere else.

### Requirements (v1)

- `@Mapper` must be attached to a `struct`.
- The struct must declare **exactly one** explicit initializer. That
  initializer's parameter list — labels, types, and order — defines the
  generated builder. Properties not part of that initializer (for example an
  `id` given a fresh default value inside the initializer body) are left
  untouched.
- Initializer parameters must be simple `label: Type` parameters: no
  variadics, no unlabeled (`_`) parameters, no parameter packs. Ownership
  specifiers (`consuming`, `borrowing`) on a parameter are supported and
  don't affect the generated builder's field type. Parameter-only attributes
  (`@escaping`, `@autoclosure`) are also stripped from the field's `Boxed<T>`
  type, while type-level attributes that are part of the type itself (e.g.
  `@MainActor`, `@Sendable` on a function-typed field) are preserved.
- Generic structs are not yet supported.
- See [Known limitations](#known-limitations) for a specific, unavoidable
  Swift compiler interaction to be aware of when a field type isn't itself
  `Equatable`/`Hashable`/`Comparable`.

These constraints are intentionally narrow for v1 — see
[Non-goals](#non-goals) for why.

## How it works

`@Mapper` is a Swift **member macro**. Given the struct above, it reads the
one explicit initializer's parameter list and adds two members: a second,
additive initializer, and a matching `@resultBuilder` enum.

```swift
extension Address {
    init(
        @AddressBuilder
        _ creation: (
            _ Street: Boxed<String>,
            _ City: Boxed<String>,
            _ PostalCode: Boxed<String>
        ) -> Self
    ) {
        self = creation(.init(), .init(), .init())
    }

    @resultBuilder
    enum AddressBuilder {
        static func buildBlock(_ street: String, _ city: String, _ postalCode: String) -> Address {
            Address(street: street, city: city, postalCode: postalCode)
        }

        static func buildBlock<Component>(_ component: Component) -> Component {
            component
        }

        static func buildEither<Component>(first component: Component) -> Component {
            component
        }

        static func buildEither<Component>(second component: Component) -> Component {
            component
        }
    }
}
```

The `buildEither` overloads (plus the generic single-field `buildBlock`) are what
let `if`/`else` and `switch` appear directly inside the builder closure — see
[Branching](#branching) below.

`Boxed<T>` (shipped once, in the `SwiftMapper` library) is a stateless
wrapper whose only job is to give each closure parameter a readable name via
`callAsFunction`, so `Street { ... }` reads like a keyword but is just an
ordinary function call. Your existing, plain initializer is left completely
untouched — the builder initializer is purely additive.

## Non-goals

- **Not a generic `Mapper<Input, Output>` runtime library.** No combinators,
  no `.pullback`, no runtime tracing/diagnostics object. If you need that,
  this library isn't it — by design.
- **Not a validation framework.** SwiftMapper does not add required-field
  checks, error accumulation, or anything beyond what the Swift compiler
  already guarantees (every builder parameter must be supplied, because
  `buildBlock`'s signature says so).
- **Not a codegen tool for entire structs.** SwiftMapper only adds a builder
  initializer next to a struct you've already written; it never generates
  your model types.

## Branching

`if`/`else` and `switch` can appear **directly** inside a builder closure —
each branch just needs to produce the same field type:

```swift
Handicap { Trend in
    switch domain.trend {
    case .up:
        Trend { .up }
    case .down:
        Trend { .down }
    case .none:
        Trend { .flat }
    }
}

PersonData { FirstName, LastName, Age in
    FirstName { "Ada" }
    LastName { "Lovelace" }
    if isSenior {
        Age { 90 }
    } else {
        Age { 36 }
    }
}
```

This works because the generated builder implements `buildEither(first:)` /
`buildEither(second:)` (for `if`/`else` and `switch`) alongside a generic
single-field `buildBlock`, so a branch that sets just one field type-checks
the same way an unconditional statement would.

### Optional fields need an explicit `else`

A plain `if` with **no** `else` is *not* supported, even for a field whose
declared type is already `Optional`. Swift's result-builder desugaring always
wraps a no-`else` branch's value in one more level of `Optional` via
`buildOptional` — for a field that's already `Optional<T>`, that produces
`T??` instead of `T?`, which won't type-check. This isn't a SwiftMapper
limitation so much as a general pitfall of Swift's result-builder machinery
when a branch's own type is already Optional, so the generated builder
intentionally doesn't implement `buildOptional` at all — write the `else`
branch explicitly instead:

```swift
NicknameData { FirstName, Nickname in
    FirstName { "Grace" }
    if hasNickname {
        Nickname { "Amazing Grace" }
    } else {
        Nickname { nil }
    }
}
```

### Not supported: partial-field branches

A branch may only set **exactly one** field per statement inside it (or all
of the struct's fields, if the branch is the closure's sole statement).
Setting a subset of two-or-more fields conditionally isn't supported — split
those fields into their own `if`/`else` (or `switch`) blocks instead.

## Diagnostics

`@Mapper` reports errors at compile time, pointing at the exact syntax that's
wrong:

- **Not a struct** — `@Mapper` can only be attached to a struct.
- **Missing initializer** — the struct must declare exactly one initializer
  whose parameters define the mapped fields.
- **Multiple initializers** — each initializer beyond the first is flagged
  individually, at its own location, so you can see exactly which ones to
  remove or merge.
- **Unsupported (variadic) parameters** — not supported by the generated
  builder.
- **Unlabeled parameters** (`_ name: String`) — flagged with a **Fix-It**
  that promotes the parameter's internal name to also be its label (turning
  `_ name: String` into `name name: String`), since that's the fix Xcode can
  apply automatically in nearly every case.
- **No fields** — the initializer must declare at least one parameter.
- **Likely `Equatable`/`Hashable`/`Comparable` conflict** (warning, not an
  error) — emitted when the struct conforms to one of those protocols *and*
  already hand-writes `==`/`<`/`hash(into:)` itself. This shape can trigger a
  known Swift compiler bug when combined with `@Mapper` — see
  [Known limitations](#known-limitations).

## Known limitations

### `Equatable`/`Hashable`/`Comparable` conflict with a hand-written witness

If a struct conforms to `Equatable`, `Hashable`, or `Comparable` **and** hand-writes
its own `==`, `hash(into:)`, or `<` (typically because a stored field — often a
function type — isn't itself Equatable/Hashable/Comparable, so the compiler
can't auto-synthesize the witness), attaching `@Mapper` to that struct can
trigger a **Swift compiler bug**, not a SwiftMapper bug:
[swiftlang/swift#70087](https://github.com/swiftlang/swift/issues/70087).

The symptom is a confusing compiler error even though the macro-generated code
is correct:

```
error: type 'Chart' does not conform to protocol 'Equatable'
note: multiple matching functions named '==' with type '(Chart, Chart) -> Bool'
note: candidate exactly matches
note: candidate exactly matches
```

**Root cause**: `@Mapper` must declare `@attached(member, names: arbitrary)`
(the generated builder init and `<Type>Builder` enum name depend on the
attached type's name, so the fixed `names: named(...)` list Swift macros can
otherwise use isn't expressible). Declaring `names: arbitrary` makes the
compiler treat `==`/`<`/`hash(into:)` as names the macro *might* generate —
even though `@Mapper` never actually generates them — which conflicts with
protocol-conformance synthesis for a hand-written witness. This reproduces
identically whether the macro is a `member` or an `extension` macro, and is
unrelated to anything project-specific; it's an upstream Swift toolchain
issue with no available workaround at the macro-author level as of this
writing.

`@Mapper` detects this specific shape (best-effort, syntax-only — it can't see
whether a field type is actually Equatable) and emits a **warning** pointing
here. If you hit the actual compiler error, **don't apply `@Mapper`** to that
struct — keep it on its plain initializer until the upstream bug is fixed.

## Development

```bash
swift build
swift test
```

## License

MIT — see [LICENSE](LICENSE).
