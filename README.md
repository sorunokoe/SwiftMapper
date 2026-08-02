# SwiftMapper

[![CI](https://github.com/sorunokoe/SwiftMapper/actions/workflows/ci.yml/badge.svg)](https://github.com/sorunokoe/SwiftMapper/actions/workflows/ci.yml)
[![Swift Package Index](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsorunokoe%2FSwiftMapper%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/sorunokoe/SwiftMapper)
[![Platform compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsorunokoe%2FSwiftMapper%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/sorunokoe/SwiftMapper)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

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
- The struct must declare **exactly one** explicit initializer, *or*, if it
  declares more than one, exactly one of them must be marked
  `@MapperCanonical` (see [Multiple initializers](#multiple-initializers)
  below). That initializer's parameter list — labels, types, and order —
  defines the generated builder. Properties not part of that initializer
  (for example an `id` given a fresh default value inside the initializer
  body) are left untouched.
- Initializer parameters must be simple `label: Type` parameters: no
  variadics, no unlabeled (`_`) parameters, no parameter packs. Ownership
  specifiers (`consuming`, `borrowing`) on a parameter are supported and
  don't affect the generated builder's field type. Parameter-only attributes
  (`@escaping`, `@autoclosure`) are also stripped from the field's `Boxed<T>`
  type, while type-level attributes that are part of the type itself (e.g.
  `@MainActor`, `@Sendable` on a function-typed field) are preserved.
- Generic structs are supported, including `where` clauses and constraints
  on the generic parameters. `@Mapper` is a *member* macro, so the generated
  builder initializer and its nested `<Type>Builder` enum sit lexically
  inside the struct's own body and see its generic parameters the same way
  any other member would — no extra syntax is needed:

  ```swift
  @Mapper
  struct LabeledValue<Value: Equatable>: Equatable {
      let label: String
      let value: Value

      init(label: String, value: Value) {
          self.label = label
          self.value = value
      }
  }

  let count = LabeledValue<Int> { Label, Value in
      Label { "count" }
      Value { items.count }
  }
  ```
- Stored `let` properties may **not** declare an in-place default value (e.g.
  `let id: UUID = .init()`) — this is a real Swift compiler limitation (not
  specific to `@Mapper`; see [Known limitations](#known-limitations)) that
  makes any additional initializer touching that property fail to compile.
  `@Mapper` detects this and raises a compile-time error with guidance; the
  fix is to declare the property without a default (`let id: UUID`) and set
  it explicitly inside the canonical initializer's body instead.
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

## Multiple initializers

`@Mapper` needs exactly one initializer to define the generated builder's
fields, but real-world structs sometimes need more than one — a
hand-written `Decodable.init(from:)`, or a convenience initializer that call
sites needing the builder never use. Attach `@MapperCanonical` to the
initializer that should define the generated builder's fields, and
`@Mapper` uses it while leaving every other initializer on the struct
completely untouched:

```swift
@Mapper
struct User: Decodable {
    let id: UUID
    let name: String

    @MapperCanonical
    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
    }
}

let user = User { Id, Name in
    Id { UUID() }
    Name { rawInput.name }
}
```

`@MapperCanonical` is a marker only — it never generates any code of its
own. It has no effect (and isn't required) when a struct declares only a
single initializer; it only matters once there's more than one to choose
from. Marking none, or more than one, of a multi-initializer struct's
initializers is a compile-time error — see [Diagnostics](#diagnostics)
below.

## Collection fields

A `[Element]`-typed field already works with the plain closure form — it's
just `Boxed<[Element]>`, and `Boxed<T>` is generic over any `T`:

```swift
Items { domain.items.map(ItemViewModel.init) }
```

For a *different* source collection mapped element-by-element, `Boxed`
also ships a `mapping:` overload so that stays a labeled call instead of a
bare `.map { }`:

```swift
@Mapper
struct Cart: Equatable {
    let itemTitles: [String]

    init(itemTitles: [String]) {
        self.itemTitles = itemTitles
    }
}

let cart = Cart { ItemTitles in
    ItemTitles(mapping: domain.items) { domainItem in
        domainItem.name.capitalized
    }
}
```

This is purely a `Boxed<T>` addition (see `Sources/SwiftMapper/BoxedCollection.swift`)
— it needed no changes to `@Mapper`'s code generation, since any `Array`-typed
field already type-checks against plain `Boxed<T>` today.

## Diagnostics

`@Mapper` reports errors at compile time, pointing at the exact syntax that's
wrong:

- **Not a struct** — `@Mapper` can only be attached to a struct.
- **Missing initializer** — the struct must declare at least one initializer
  whose parameters define the mapped fields.
- **Multiple initializers** — emitted at every initializer when a struct
  declares more than one and none of them is marked `@MapperCanonical`,
  with a **Fix-It** that inserts `@MapperCanonical` above that initializer.
  See [Multiple initializers](#multiple-initializers) above.
- **Multiple canonical initializers** — emitted at each initializer marked
  `@MapperCanonical` when more than one is marked on the same struct; only
  one is allowed.
- **Unsupported (variadic) parameters** — not supported by the generated
  builder.
- **Unlabeled parameters** (`_ name: String`) — flagged with a **Fix-It**
  that promotes the parameter's internal name to also be its label (turning
  `_ name: String` into `name name: String`), since that's the fix Xcode can
  apply automatically in nearly every case.
- **No fields** — the initializer must declare at least one parameter.
- **Colliding capitalized field labels** — emitted when two initializer
  parameters capitalize to the same generated builder closure parameter
  name (for example `name` and `Name`), which would otherwise silently
  produce an invalid, duplicate-named parameter in the generated builder
  initializer. Rename one of the two parameters to fix it.
- **Default-valued `let` property** (error) — emitted when a stored `let`
  property declares an in-place default value (e.g. `let id: UUID = .init()`).
  This always breaks the build once `@Mapper`'s generated builder init is
  added — see [Known limitations](#known-limitations) for why, and how to fix
  it.
- **Likely `Equatable`/`Hashable`/`Comparable` conflict** (warning, not an
  error) — emitted when the struct conforms to one of those protocols *and*
  already hand-writes `==`/`<`/`hash(into:)` itself. This shape can trigger a
  known Swift compiler bug when combined with `@Mapper` — see
  [Known limitations](#known-limitations).

## Known limitations

### Stored `let` properties can't have an in-place default value

A stored `let` property declared with an in-place default value, e.g.:

```swift
struct Chart: Identifiable {
    let id: UUID = .init()
    let value: String
    ...
}
```

can never be assigned by any initializer other than the implicit default-value
prologue Swift inserts for it — not even by explicitly writing `self.id = ...`
in your own initializer, and not by a whole-`self` reassignment like
`self = other`. Any attempt produces:

```
error: immutable value 'self.id' may only be initialized once
```

**This is a genuine Swift compiler limitation, unrelated to macros or
`@Mapper`** — it reproduces with a plain, hand-written struct and no macros at
all. `@Mapper`'s generated builder initializer always does
`self = creation(...)` to assemble the full value from the builder closure, so
any struct with this shape will always fail to compile once `@Mapper` is
attached.

**Fix**: don't give the property an in-place default. Declare it without one
and set it explicitly inside the canonical initializer's body instead:

```swift
struct Chart: Identifiable {
    let id: UUID
    let value: String

    init(value: String) {
        self.id = .init()
        self.value = value
    }
}
```

`@Mapper` detects this shape deterministically (unlike the Equatable case
below, this isn't a heuristic — it's always broken) and raises a compile-time
**error** pointing at the offending property.

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

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR that adds
capability rather than fixing something existing — this repo uses a short
plan/spec convention under `docs/superpowers/` for anything that grows the
library's surface area.

## Documentation

Full symbol documentation (including this README's examples) renders via
DocC — open the package in Xcode and build documentation
(**Product ▸ Build Documentation**), or browse it once published on the
[Swift Package Index](https://swiftpackageindex.com/sorunokoe/SwiftMapper/documentation).

## License

MIT — see [LICENSE](LICENSE).
