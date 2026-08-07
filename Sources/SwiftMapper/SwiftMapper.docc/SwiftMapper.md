# ``SwiftMapper``

A tiny Swift macro that turns a struct or class's own initializer into a
composable, type-safe "field builder" DSL — without a runtime combinator
library, and without hand-writing a `@resultBuilder` for every type you map
into.

## Overview

Attach ``Mapper()`` to a struct or class and its own canonical initializer
becomes a labeled, compile-time-checked builder closure: every field must be
supplied, in the right type, with zero runtime cost (no protocol witnesses,
no boxed existentials, no reflection).

```swift
@Mapper
public struct ProfileHeaderData: Equatable, Sendable {
    public let id: UUID
    public let profile: Avatar
    public let fullname: String
    public let nickname: String

    public init(id: UUID, profile: Avatar, fullname: String, nickname: String) {
        self.id = id
        self.profile = profile
        self.fullname = fullname
        self.nickname = nickname
    }
}

let header = ProfileHeaderData {
    Profile { domainUser.avatar }
    Fullname { domainUser.displayName }
    Nickname { domainUser.nickname ?? domainUser.displayName }
}

// Equivalent, flatter alternative — no block, one ordinary argument per field:
let sameHeader = ProfileHeaderData(
    profile: { domainUser.avatar },
    fullname: { domainUser.displayName },
    nickname: { domainUser.nickname ?? domainUser.displayName }
)
```

SwiftMapper deliberately stays a *third path* between a flat initializer call
(easy to get subtly wrong) and a generic runtime `Mapper<Input, Output>`
combinator library (readable, but its own abstraction and learning curve).
There is no runtime combinator layer and no validation/error-accumulation
framework hiding behind the macro — everything it generates is ordinary,
inspectable Swift you could have hand-written yourself.

If a type declares more than one initializer, ``Mapper()`` first tries to
auto-detect the memberwise-shaped one (an initializer whose parameter labels
exactly match the type's stored properties) as canonical. ``MapperCanonical()``
only needs to be attached explicitly when that auto-detection is ambiguous —
for example, when a type has several initializers and none, or more than
one, matches its stored properties exactly.

## Topics

### Attaching the macro

- ``Mapper()``
- ``MapperCanonical()``

### Field values

- ``Boxed``

### Guides

For generics, class support, multiple initializers, collection fields,
branching, and the full diagnostics list, see the project README and
[docs/GUIDE.md](https://github.com/sorunokoe/SwiftMapper/blob/main/docs/GUIDE.md).
