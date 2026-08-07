# Guide

Deeper detail that doesn't belong in the README: how `@Mapper` expands,
the full `Rule` composition story, branching edge cases, multiple
initializers, collection fields, and the full diagnostics list.

## How `@Mapper` expands

`@Mapper` is a Swift **member macro**. It reads your one initializer and
adds three members: two additive initializers, and a matching
`@resultBuilder` enum.

```swift
extension Address {
    init(
        @Builder
        _ creation: (
            _ Street: Boxed<String>,
            _ City: Boxed<String>,
            _ PostalCode: Boxed<String>
        ) -> (String, String, String)
    ) {
        let (street, city, postalCode) = creation(.init(), .init(), .init())
        self.init(street: street, city: city, postalCode: postalCode)
    }

    init(
        street: () -> String,
        city: () -> String,
        postalCode: () -> String
    ) {
        self.init(street: street(), city: city(), postalCode: postalCode())
    }

    @resultBuilder
    enum Builder {
        static func buildBlock(_ street: String, _ city: String, _ postalCode: String) -> (String, String, String) {
            (street, city, postalCode)
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

The `buildEither` overloads (plus the single-field `buildBlock`) are what
let `if`/`else` and `switch` appear directly inside the builder closure
(see [Branching](#branching)).

`Boxed<T>` gives each closure parameter a readable name via
`callAsFunction`, so `Street { ... }` reads like a keyword but is an
ordinary function call. The keyword initializer needs no such helper — its
fields are already ordinary, independently labeled closures. Your existing
initializer is left untouched — both generated initializers are purely
additive.

## Composing field logic with `Rule`

`@Mapper` solves "one struct, several fields." `Rule` solves a smaller
problem: what a single field's mapping logic looks like once it outgrows
one line, so it doesn't collapse into a private helper method.

```swift
public protocol Rule<Input, Output> {
    associatedtype Input
    associatedtype Output
    var input: Input { get }
    var body: Output { get }
}
```

That's the whole protocol — deliberately mirroring `View.body`: one
computed property, no combinators, no environment.

**Pure rules** need only `input` — construct them at the call site, the
same way `Text("x")` needs no injection:

```swift
struct TournamentTypeRule: Rule {
    let input: DomainTournamentType

    var body: TournamentType {
        switch input {
        case .bullsEye: .bullsEye
        case .puttPutt: .puttPutt
        // ...
        }
    }
}

TournamentType { TournamentTypeRule(input: domain.tournamentType).execute() }
```

**Context-needing rules** take extra, constructor-injected collaborators —
bundle a small `Input` type when a rule needs more than one value:

```swift
struct TournamentInfoBannerRule: Rule {
    struct Input {
        let eventStatus: DomainEventStatus
        let playerPosition: DomainPlayerPosition
    }

    let input: Input
    let placementBannerMapper: PlacementBannerToPresentationMapper
    let scheduledToTagTextMapper: ScheduledStatusToTagTextPresentationMapper

    var body: InfoCardBarArrangement { /* ... */ }
}
```

`Rule` and `@Mapper` compose freely — a `Rule`'s `body` can construct and
invoke a `@Mapper` builder, and a builder closure can construct and invoke
a `Rule`. Neither needs the other.

### Calling a rule — `.execute()`, not `.body`

Call `.execute()` everywhere outside `RuleBuilder`'s own implementation:

```swift
let mapped = TournamentTypeRule(input: domain.tournamentType).execute()
```

`.execute()` is just `{ body }`. Prefer it over `.body` because `.body`
reads like an ordinary stored property, which invites chaining more
operations off it (`.body.map { ... }`, `.body ?? fallback`) — exactly the
combinator shape this library avoids. Branch with plain `if let`/`guard
let`/`switch` instead:

```swift
// ❌ chains a combinator off the rule's result
let arrangement = ScheduledStatusToTagTextRule(input: scheduled).execute().value.map { ... } ?? .none

// ✅ invoke, then branch with ordinary control flow
guard let text = ScheduledStatusToTagTextRule(input: scheduled).execute().value else { return .none }
```

A rule can also chain directly into the next expression via
`callAsFunction`, with no `.execute()` at that step — Swift attaches a
trailing closure automatically right after a rule's initializer call:

```swift
PlayerPositionFromExpandedInfoRule(input: expandedInfo) { playerPosition in
    PlayerPositionRule(input: .init(playerPosition: playerPosition, positionScore: positionScore))
}
```

The whole expression has type `PlayerPositionRule.Output`. A second
overload covers the same shape when the continuation produces a plain
value instead of another rule:

```swift
EventStatusToDateRule(input: input.status) { dateRange in
    InfoCardTextArrangement.threeItems(
        headlineTextItem: .headLine(label: input.name),
        subtitleTextItem: .subtitle(label: dateRange),
        primaryInfoTextItem: LeagueInviteCardFeatureListRule(input: input).execute()
    )
}
```

### `RuleBuilder`'s tail-delegation sugar

`body` is declared `@RuleBuilder<Output>` (see
`Sources/SwiftMapper/RuleBuilder.swift`), mirroring `@ViewBuilder var body:
Body { get }`. When a `Rule`'s `body` is **pure tail delegation to one
child rule — no `return` anywhere in the property** — construct that child
directly, no `.execute()` needed:

```swift
struct TournamentTypeBadgeRule: Rule {
    let input: DomainTournamentType

    var body: TournamentType {
        TournamentTypeRule(input: input)   // invoked for you
    }
}
```

This also works for `switch`/`if`-`else` as the body's sole expression,
mixing plain values and child rules per branch:

```swift
var body: TournamentLeaderboardFiltersData? {
    switch onEnum(of: input.expandedInfo) {
    case let .CourseRoundExpanded(courseRound):
        CourseRoundLeaderboardFiltersRule(input: .init(expandedInfo: input.expandedInfo, courseRound: courseRound))
    case .ClosestToPinExpanded, .LongestDriveExpanded:
        LocationLeaderboardFiltersRule(input: input.expandedInfo)
    default:
        nil
    }
}
```

And for an array-typed `Output`, one rule (or value) per line — the same
"one row per line" shape as `ForEach`, but for a fixed, statically known
set of rows:

```swift
var body: [DataState<TournamentSettingsItemData>] {
    TournamentSettingsAttemptsRule(input: input.attempts)
    TournamentSettingsGameNameRule(input: input.courseName)
    TournamentSettingsHolesRule(input: input.puttPuttTournament.numberOfHoles)
    BooleanSettingsItemRule(input: .init(headline: .tieBreaker, enabled: input.isTieBreakerEnabled))
    TournamentSettingsParticipantsRule(input: input.puttPuttTournament.participants)
}
```

This only resolves the body's own tail expression, one level deep. It
stops helping the moment a `return` appears anywhere in the property
(Swift falls back to ordinary getter semantics for the whole property — a
general Swift rule, not specific to `RuleBuilder`), or when a child rule's
value is:

- assigned to an intermediate `let` and used later — use the chaining
  `callAsFunction(_:)` overload above instead,
- one argument among several in a larger initializer or function call,
- the receiver of a further member-access chain,
- inside a nested closure like `.map { ChildRule(input: $0) }`.

For any of those, invoke the rule explicitly:

```swift
var body: InfoCardBarArrangement {
    let placementBanner = placementBannerMapper.map(...)
    if case .visible = placementBanner { return placementBanner }
    guard case let .scheduled(scheduled) = onEnum(of: input.eventStatus) else { return .none }
    return ScheduledInfoBannerRule(input: .init(scheduled: scheduled)).execute()
}
```

A `@Mapper`-generated `Boxed<T>` field also accepts a closure returning
`some Rule<_, T>` directly, invoking it for you:

```swift
// equivalent — Boxed invokes the rule for you when the closure returns a Rule:
TournamentType { TournamentTypeRule(input: domain.tournamentType) }
```

This also resolves the case where the field's type is `Optional` and the
rule's `Output` is the non-optional wrapped type — no `Optional(...)`
wrapping or cast needed at the call site.

### `Rule` non-goals

- **No generic value combinators.** No `.pullback`, no `.map`/`??` chained
  off a stored result. The continuation `callAsFunction(_:)` overloads are
  one direct hop into the next expression, evaluated immediately — not a
  standalone operator you chain further off of.
- **`.body` is a convention, not compiler-enforced.** Swift can't make a
  protocol requirement less accessible than the protocol itself, so
  nothing stops a call site from writing `.body` directly. Treat it like
  reading `someView.body` in SwiftUI — it compiles, and it's still wrong.
  Catch it in review (`grep -rn '\.body' Sources/`, excluding
  `RuleBuilder`/`Boxed` themselves).
- **No tree-walking, no ambient dependency resolution.** Dependencies are
  always threaded explicitly. `RuleBuilder` resolves exactly one level per
  composed child, statically — there's no DI container or rendering
  engine underneath.
- **Not retrofitted onto every mapper.** Adopt it for new, genuinely
  single-input leaf rules; a mapper that naturally takes several labeled
  parameters keeps that shape.

## Branching

`if`/`else` and `switch` can appear directly inside a builder closure —
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

A plain `if` with **no** `else` isn't supported, even for an
already-Optional field — Swift's result-builder desugaring would wrap it
in one more level of `Optional`, producing `T??`. Write the `else`
explicitly:

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

Each branch may only set **exactly one** field per statement (or all
fields, if the branch is the closure's only statement) — split
multi-field conditions into their own `if`/`else` blocks.

## Multiple initializers

`@Mapper` needs exactly one initializer to define the builder's fields,
but real types sometimes have more than one — a hand-written
`Decodable.init(from:)`, say. `@Mapper` first tries auto-detection: if
exactly one initializer's parameter labels exactly match the type's
stored property names, that one is used automatically:

```swift
@Mapper
struct User: Decodable {
    let id: UUID
    let name: String

    // Auto-detected: labels match the stored properties; init(from:) isn't a candidate.
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

If auto-detection can't find exactly one unambiguous candidate, attach
`@MapperCanonical` to the initializer that should define the builder — it
always wins, and every other initializer is left untouched:

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

    init(from decoder: Decoder) throws { /* ... */ }
}
```

`@MapperCanonical` is a marker only — it generates no code, and has no
effect on a type with just one initializer. Marking two initializers on
the same type is a compile-time error, and so is auto-detection finding
more than one candidate — see [Diagnostics](#diagnostics).

## Collection fields

Array fields already work with the plain closure form:

```swift
Items { domain.items.map(ItemViewModel.init) }
```

For a different source collection mapped element-by-element, `Boxed`
also ships a `mapping:` overload so the call stays labeled instead of a
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

`mapping:` also has a `Rule`-returning overload, so each element can come
from a per-element `Rule` directly, no trailing `.execute()`:

```swift
Items(mapping: domain.items) { domainItem in
    ItemRule(input: domainItem)
}
```

## Diagnostics

`@Mapper` reports errors at compile time, pointing at the exact syntax
that's wrong — with a Fix-It where one makes sense:

- **Not a struct or class.**
- **Missing initializer.**
- **Multiple initializers**, none canonical or auto-detected — Fix-It
  inserts `@MapperCanonical` above each one.
- **Multiple canonical initializers** — only one `@MapperCanonical` is
  allowed per type.
- **Unsupported (variadic) parameters.**
- **Unlabeled parameters** (`_ name: String`) — Fix-It promotes the
  internal name to also be the label.
- **No fields** — the initializer needs at least one parameter.
- **Colliding capitalized field labels** — e.g. `name` and `Name` would
  otherwise produce a duplicate-named builder parameter. Rename one.
- **Existing `Builder` member collision** — rename that member, or don't
  apply `@Mapper` here.
