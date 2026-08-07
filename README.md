# SwiftMapper

[![CI](https://github.com/sorunokoe/SwiftMapper/actions/workflows/ci.yml/badge.svg)](https://github.com/sorunokoe/SwiftMapper/actions/workflows/ci.yml)
[![Swift Package Index](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsorunokoe%2FSwiftMapper%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/sorunokoe/SwiftMapper)
[![Platform compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsorunokoe%2FSwiftMapper%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/sorunokoe/SwiftMapper)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small Swift library for writing data mappers that read like a DSL and
type-check at compile time — no runtime combinator library, no
hand-written `@resultBuilder` per type.

## The problem

Hand-written mappers tend to go one of two ways: a flat initializer call
(easy to get subtly wrong — arguments in the wrong order, a field mapped
from the wrong source) or a generic `Mapper<Input, Output>` combinator
library (readable, but drags in a runtime abstraction and its own
learning curve).

SwiftMapper takes a third path: each field gets its own small, labeled
closure, and the compiler checks that every one is supplied — at compile
time, zero runtime cost.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/sorunokoe/SwiftMapper.git", from: "1.0.0"),
]
```

Add `SwiftMapper` to your target's dependencies.

## Usage

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

// Equivalent, flatter form — no block, one ordinary argument per field:
let sameAddress = Address(
    street: { rawInput.line1 },
    city: { rawInput.city.capitalized },
    postalCode: { rawInput.zip.trimmed() }
)
```

`@Mapper` reads your struct's own initializer and adds both of these
initializers next to it — your original initializer is untouched. It
attaches to a `struct`/`class` with one initializer: plain `label: Type`
parameters only (no variadics, no unlabeled/`_` params). If a type has
several initializers, `@Mapper` auto-detects the memberwise-shaped one, or
you can mark the right one with `@MapperCanonical`.

## `Rule`: composing a field that outgrows one line

```swift
protocol Rule<Input, Output> {
    associatedtype Input
    associatedtype Output
    var input: Input { get }
    var body: Output { get }
}

struct TournamentTypeRule: Rule {
    let input: DomainTournamentType

    var body: TournamentType {
        switch input {
        case .bullsEye: .bullsEye
        case .puttPutt: .puttPutt
        }
    }
}

TournamentType { TournamentTypeRule(input: domain.tournamentType).execute() }
```

One computed property, no combinators, no environment — deliberately
mirroring `View.body`. `Rule` and `@Mapper` compose freely in either
direction. See [docs/GUIDE.md](docs/GUIDE.md) for chaining rules,
branching (`if`/`switch` inside a builder), multiple initializers,
collection fields, and the full diagnostics list.

## More examples

**Branching** — `if`/`else` and `switch` work directly inside a builder
closure, as long as every branch produces the same field type:

```swift
Handicap { Trend in
    switch domain.trend {
    case .up: Trend { .up }
    case .down: Trend { .down }
    case .none: Trend { .flat }
    }
}
```

**Collections** — map a source collection element-by-element, labeled
instead of a bare `.map`:

```swift
Items(mapping: domain.items) { domainItem in
    domainItem.name.capitalized
}
```

**Multiple initializers** — `@Mapper` auto-detects the memberwise-shaped
initializer; mark another explicitly with `@MapperCanonical` when that's
ambiguous (e.g. alongside a hand-written `Decodable.init(from:)`):

```swift
@Mapper
struct User: Decodable {
    let id: UUID
    let name: String

    init(id: UUID, name: String) { self.id = id; self.name = name } // auto-detected
    init(from decoder: Decoder) throws { /* ... */ }                 // not a candidate
}
```

More in [docs/GUIDE.md](docs/GUIDE.md) — rule chaining, diagnostics, and
class support.

## Non-goals

- Not a generic `Mapper<Input, Output>` combinator library.
- Not a validation framework — no required-field checks or error
  accumulation beyond what the compiler already guarantees.
- Not a codegen tool for whole structs — it only adds a builder
  initializer next to a struct you've already written.

## Development

```bash
swift build
swift test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR that grows the
library's surface area.

## Performance

Zero runtime cost (the generated builder fully inlines away in a release
build) and no macro-expansion re-parsing. See
[docs/BENCHMARKING.md](docs/BENCHMARKING.md) to reproduce the numbers.

## Documentation

Full symbol documentation renders via DocC — open the package in Xcode
(**Product ▸ Build Documentation**), or browse it on the
[Swift Package Index](https://swiftpackageindex.com/sorunokoe/SwiftMapper/documentation).

## License

MIT — see [LICENSE](LICENSE).
