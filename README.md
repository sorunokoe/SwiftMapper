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
  variadics, no unlabeled (`_`) parameters, no parameter packs.
- Generic structs are not yet supported.

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
    }
}
```

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

## A note on branching

A `switch` (or `if`/`else`) statement cannot appear directly inside a
`@resultBuilder`-annotated closure unless the builder implements
`buildEither`/`buildOptional` for every branch shape — which the generated
builder does not. Compute branch results with a **switch expression** (or a
plain helper function) outside the labeled closure, then reference the
already-computed value inside it:

```swift
let trend: TrendIndicator = switch domain.trend {
case .up: .up
case .down: .down
case .none: .flat
}

Handicap { Trend in
    Trend { trend }
}
```

## Development

```bash
swift build
swift test
```

## License

MIT — see [LICENSE](LICENSE).
