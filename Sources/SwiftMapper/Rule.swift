/// A single, self-contained mapping rule — the `Rule` equivalent of SwiftUI's `View`.
///
/// `Rule` has exactly one computed-property requirement, mirroring `View.body`: no
/// combinators, no environment, no ambient lookup, and no framework walking a tree of rules
/// for you. `input` is always threaded in explicitly (via whatever initializer the
/// conforming type declares); `body` simply computes `Output` from `input` — and, for
/// context-needing rules, from whatever other collaborators the type explicitly stores — the
/// moment it's read.
///
/// ```swift
/// struct TournamentTypeRule: Rule {
///     let input: DomainTournamentType
///
///     var body: TournamentType {
///         switch input {
///         case .bullsEye: .bullsEye
///         case .puttPutt: .puttPutt
///         // ...
///         }
///     }
/// }
///
/// // no DI, no registration — just construct it and invoke it:
/// let mapped = TournamentTypeRule(input: domain.tournamentType)()
/// ```
///
/// A context-needing rule keeps explicit, constructor-injected collaborators alongside its
/// `input` — the same pattern any other dependency-consuming mapper already uses:
///
/// ```swift
/// struct TournamentInfoBannerRule: Rule {
///     struct Input {
///         let eventStatus: DomainEventStatus
///         let playerPosition: DomainPlayerPosition
///     }
///
///     let input: Input
///     let placementBannerMapper: PlacementBannerToPresentationMapper
///     let scheduledToTagTextMapper: ScheduledStatusToTagTextPresentationMapper
///
///     var body: InfoCardBarArrangement {
///         // ...
///     }
/// }
/// ```
///
/// ## Invoking a Rule — `callAsFunction()`, not `.body`
///
/// `body` is a protocol requirement, so Swift cannot make it any less accessible than `Rule`
/// itself (`Rule` has to be `public` to be conformed to across module boundaries) — but it is
/// meant to be read in exactly two places: `RuleBuilder`'s own implementation, and a `Rule`'s
/// pure tail-delegation to one child rule (both are what `@RuleBuilder<Output>` exists for).
/// Everywhere else — a `Mapper`, an interactor, a test, an intermediate `let` binding, or any
/// other call site outside a `Rule`'s own `body` — call the rule instead of reading `.body`:
///
/// ```swift
/// let mapped = TournamentTypeRule(input: domain.tournamentType)()
/// ```
///
/// `callAsFunction()` is exactly `{ body }` — invoking a rule and reading its `body` are the
/// same operation. The point of preferring `()` is what it *rules out*: `.body` reads like an
/// ordinary stored property, which invites chaining further operations directly onto it
/// (`.body.map { ... }`, `.body ?? fallback`) — exactly the generic-combinator shape this
/// library rejects (see [Non-goals](../../../README.md#non-goals)). Treat a rule's result the
/// same way you'd treat any other domain value once you have it: branch with plain
/// `if let`/`guard let`/`switch`, never `.map`/`??` chained directly off the invocation:
///
/// ```swift
/// // ❌ chains a combinator directly off the rule's result
/// let arrangement = ScheduledStatusToTagTextRule(input: scheduled)().value.map { ... } ?? .none
///
/// // ✅ invoke, then branch with ordinary control flow
/// guard let text = ScheduledStatusToTagTextRule(input: scheduled)().value else { return .none }
/// ```
///
/// A second `callAsFunction` overload chains one rule directly into another — invoking this
/// rule, feeding its `Output` to `continuation`, and returning the *resulting* rule's own
/// invocation, with no intermediate `let` binding and no `.body` at either step:
///
/// ```swift
/// PlayerPositionFromExpandedInfoRule(input: expandedInfo) { playerPosition in
///     PlayerPositionRule(input: .init(playerPosition: playerPosition, positionScore: positionScore))
/// }
/// ```
///
/// The whole expression above has type `PlayerPositionRule.Output` — usable anywhere that
/// type is expected (a `body`'s tail expression, a builder field, a `let` binding, a plain
/// function argument). `continuation` is constrained to return *another `Rule`*, never a bare
/// transformed value — this only ever composes one rule directly into the next, the same way
/// nesting `View`s composes views; it is not a disguised `.map` over arbitrary output types
/// (see [`Rule` non-goals](../../../README.md#rule-non-goals)).
///
/// ## Design history
///
/// An earlier version of this protocol (SwiftMapper `1.2.0`, named `Mapping`) used a single
/// `func map(_ input: Input) -> Output` requirement instead of a stored `input` + computed
/// `body`. It was reshaped into `Rule` to read closer to SwiftUI's own vocabulary. Two more
/// literal readings of "make it exactly like `View`" were considered and rejected along the
/// way:
///
/// - **A recursive, framework-walked tree of `Rule`s**, resolved the way SwiftUI privately
///   resolves `some View` via `_makeView` — replicating that here means writing that walker
///   ourselves, which is exactly the kind of runtime combinator/engine this library's
///   [Non-goals](../../../README.md#non-goals) section already rejects. `body` is marked
///   `@RuleBuilder<Output>` (see `RuleBuilder`), which resolves *one* level of a composed
///   child's `.body` for you — a lighter-weight, non-recursive relative of this idea, not a
///   reversal of the rejection: nothing walks a `Rule` tree at runtime, and a multi-statement
///   `body` (anything using `guard`/`return`) falls back to plain, unsugared getter semantics.
/// - **Zero-argument leaf construction** (a sub-rule built with no input, relying on a
///   framework to supply it once the tree is walked) — this is environment-style implicit
///   dependency injection, which `CONTRIBUTING.md` explicitly forbids: *"Context/dependency
///   parameters ... should be threaded explicitly ... not looked up ambiently/globally."*
///
/// `Rule` keeps the part of that request that's achievable without an engine or ambient
/// lookup: a `body` computed property instead of a `map` function, with `input` always
/// threaded in explicitly.
///
/// ## Non-goals
///
/// - **No generic value combinators.** `Rule` doesn't grow `.pullback`, `.map`, or any
///   operator that transforms an arbitrary `Output` into some other type — SwiftMapper's
///   top-level Non-goals section already rejects a runtime combinator library, and `Rule`
///   doesn't change that. The chaining `callAsFunction(_:)` overload (see "Invoking a Rule"
///   above) is not an exception: its continuation is constrained to return *another `Rule`*,
///   never a bare value, so it composes rules — the same way nesting `View`s composes views —
///   rather than transforming a value through an arbitrary closure.
/// - **No recursive, multi-level tree walking**, and **no ambient/environment-style
///   dependency resolution** — see Design history above. `RuleBuilder` resolves exactly one
///   level of `.body` per composed child, statically, at the call site; it is not a rendering
///   engine, and `Rule` is still not a DI container. The "no need to inject it" ergonomics for
///   a pure rule come entirely from a type having no stored dependencies beyond its own
///   `input`, not from a hidden lookup mechanism.
/// - **Not a replacement for `@Mapper`.** `@Mapper` generates a labeled builder initializer
///   for a struct with several fields; `Rule` names the shape of one small, single-input/
///   single-output rule that a `@Mapper`-generated builder closure (or any other call site)
///   can construct and read. The two compose — a `Rule`'s `body` is a perfectly normal place
///   to construct and call an `@Mapper`-annotated type's builder initializer — but neither
///   requires the other.
/// - **Not retrofitted onto every existing mapper.** `Rule` is additive: adopt it for new,
///   genuinely single-input leaf rules. A mapper whose natural shape takes several labeled
///   parameters, or that dispatches across a sealed type's cases before delegating to a
///   specialized rule, keeps that shape — bundle a small `Input` type only when it reads
///   better than the alternative.
public protocol Rule<Input, Output> {
    associatedtype Input
    associatedtype Output

    /// The value this rule maps from. Always supplied explicitly, via whatever initializer
    /// the conforming type declares — never looked up ambiently.
    var input: Input { get }

    /// The mapped result, computed from `input` (and, for context-needing rules, from
    /// whatever collaborators the type explicitly stores) the moment it's read. The one and
    /// only computed requirement — deliberately mirroring `View.body`.
    ///
    /// Marked `@RuleBuilder<Output>` so a `body` that's pure tail delegation to one child rule
    /// (no `return` anywhere in the property) can construct that child directly, with no
    /// `.body` and no `Boxed()` wrapper — see `RuleBuilder` for exactly what this does and
    /// does not cover.
    @RuleBuilder<Output>
    var body: Output { get }
}

public extension Rule {
    /// Invokes this rule and returns its `Output` — the sanctioned way to read a rule's
    /// result from anywhere outside a `Rule`'s own `body` (a `Mapper`, an interactor, a test,
    /// an intermediate `let` binding, ...). See "Invoking a Rule" above for why this is
    /// preferred over reading `.body` directly.
    func callAsFunction() -> Output {
        body
    }

    /// Chains this rule directly into another: invokes this rule, feeds its `Output` to
    /// `continuation`, and returns the *resulting* rule's own invocation — composing two
    /// rules in one expression, with no intermediate `let` binding and no `.body` at either
    /// step. `continuation` must return another `Rule`; see "Invoking a Rule" above for why
    /// that constraint keeps this from becoming a generic value combinator.
    func callAsFunction<R: Rule>(_ continuation: (Output) -> R) -> R.Output {
        continuation(self())()
    }
}

