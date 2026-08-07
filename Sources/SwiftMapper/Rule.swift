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
/// let mapped = TournamentTypeRule(input: domain.tournamentType).execute()
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
/// ## Invoking a Rule — `.execute()`, not `.body`
///
/// `body` is a protocol requirement, so Swift cannot make it any less accessible than `Rule`
/// itself (`Rule` has to be `public` to be conformed to across module boundaries) — but it is
/// meant to be read in exactly two places: `RuleBuilder`'s own implementation, and a `Rule`'s
/// pure tail-delegation to one child rule (both are what `@RuleBuilder<Output>` exists for).
/// Everywhere else — a `Mapper`, an interactor, a test, an intermediate `let` binding, or any
/// other call site outside a `Rule`'s own `body` — call `.execute()` instead of reading `.body`:
///
/// ```swift
/// let mapped = TournamentTypeRule(input: domain.tournamentType).execute()
/// ```
///
/// `execute()` is exactly `{ body }` — invoking a rule and reading its `body` are the same
/// operation. The point of preferring `execute()` is what it *rules out*: `.body` reads like
/// an ordinary stored property, which invites chaining further operations directly onto it
/// (`.body.map { ... }`, `.body ?? fallback`) — exactly the generic-combinator shape this
/// library rejects (see [Non-goals](../../../README.md#non-goals)). Treat a rule's result the
/// same way you'd treat any other domain value once you have it: branch with plain
/// `if let`/`guard let`/`switch`, never `.map`/`??` chained directly off the invocation:
///
/// ```swift
/// // ❌ chains a combinator directly off the rule's result
/// let arrangement = ScheduledStatusToTagTextRule(input: scheduled).execute().value.map { ... } ?? .none
///
/// // ✅ invoke, then branch with ordinary control flow
/// guard let text = ScheduledStatusToTagTextRule(input: scheduled).execute().value else { return .none }
/// ```
///
/// A rule also supports continuation chaining — composing this rule directly into another
/// expression by constructing it with a trailing closure, no `.execute()` at that step, the
/// same "call it like a function" ergonomic Swift's `callAsFunction` gives any other type:
///
/// ```swift
/// PlayerPositionFromExpandedInfoRule(input: expandedInfo) { playerPosition in
///     PlayerPositionRule(input: .init(playerPosition: playerPosition, positionScore: positionScore))
/// }
/// ```
///
/// The whole expression above has type `PlayerPositionRule.Output` — usable anywhere that
/// type is expected (a `body`'s tail expression, a builder field, a `let` binding, a plain
/// function argument). This reads no differently than constructing any other rule — the
/// trailing closure is Swift attaching to the constructed rule's own `callAsFunction`, not a
/// separate method call to remember.
///
/// A second overload covers the same shape when `continuation` produces a plain value instead
/// of another rule — most useful when a rule's result is only one piece of a larger literal:
///
/// ```swift
/// EventStatusToDateRule(input: input.status) { dateRange in
///     InfoCardTextArrangement.threeItems(
///         headlineTextItem: .headLine(label: input.name),
///         subtitleTextItem: .subtitle(label: dateRange),
///         primaryInfoTextItem: LeagueInviteCardFeatureListRule(input: input).execute()
///     )
/// }
/// ```
///
/// Both overloads compose one rule directly into the next expression, the same way nesting
/// `View`s composes views; neither is a disguised `.map` over arbitrary output types — there
/// is still no optional-promotion, no `??` fallback, and no further chaining off the result
/// (see [`Rule` non-goals](../../../docs/GUIDE.md#rule-non-goals)). Only the zero-argument
/// invocation — the one call site that genuinely benefits from an explicit, unambiguous verb
/// (see above) — uses `.execute()`; a continuation is already self-describing via its closure
/// parameter, so it uses ordinary call syntax instead.
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
/// - **No generic value combinators.** `Rule` doesn't grow `.pullback`, or a `.map`/`??` you
///   chain repeatedly off a stored result later — SwiftMapper's top-level Non-goals section
///   already rejects a runtime combinator library, and `Rule` doesn't change that. The two
///   continuation `callAsFunction(_:)` overloads (see "Invoking a Rule" above) are not an
///   exception: each is one direct hop from this rule's `Output` straight into the very next
///   expression — a child rule's invocation or a plain value — evaluated immediately at the
///   call site, never a standalone operator you store and chain further off of. Composing
///   more still means invoking the next rule directly, the same way nesting `View`s composes
///   views, not chaining a generic combinator off an intermediate result.
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
    func execute() -> Output {
        body
    }

    /// Chains this rule directly into another: constructing this rule with a trailing
    /// closure invokes it, feeds its `Output` to `continuation`, and returns the *resulting*
    /// rule's own invocation — composing two rules in one expression, with no intermediate
    /// `let` binding, no `.body`, and no explicit `.execute()` at either step. This is
    /// `callAsFunction`, not a named method — Swift attaches the trailing closure to it
    /// automatically whenever a rule's initializer call is immediately followed by one.
    func callAsFunction<R: Rule>(_ continuation: (Output) -> R) -> R.Output {
        continuation(execute()).execute()
    }

    /// Chains this rule's result into a plain expression: constructing this rule with a
    /// trailing closure invokes it, feeds its `Output` to `continuation`, and returns
    /// whatever value `continuation` produces — with no intermediate `let` binding, no
    /// `.body`, and no explicit `.execute()` at either step. Most useful nested inside a
    /// larger expression (one field of a struct literal, one argument among several) where
    /// introducing a `let` just to read one rule's result would break up the expression that
    /// reads it:
    ///
    /// ```swift
    /// EventStatusToDateRule(input: input.status) { dateRange in
    ///     InfoCardTextArrangement.threeItems(
    ///         headlineTextItem: .headLine(label: input.name),
    ///         subtitleTextItem: .subtitle(label: dateRange),
    ///         primaryInfoTextItem: LeagueInviteCardFeatureListRule(input: input).execute()
    ///     )
    /// }
    /// ```
    ///
    /// Swift picks the `R: Rule` overload above whenever `continuation` returns another rule
    /// matching the call site's expected type; this overload only ever fires otherwise (a
    /// bare value, or a rule read as itself rather than invoked). It is still not a disguised
    /// `.map`: there is no optional-promotion, no `??` fallback, and no further chaining off
    /// the result — treat the returned value the same way you would any other rule's output
    /// once you have it, with ordinary `if let`/`guard let`/`switch`.
    func callAsFunction<Result>(_ continuation: (Output) -> Result) -> Result {
        continuation(execute())
    }
}

