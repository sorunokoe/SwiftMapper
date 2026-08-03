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
/// // no DI, no registration — just construct it and read `body`:
/// let mapped = TournamentTypeRule(input: domain.tournamentType).body
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
/// ## Design history
///
/// An earlier version of this protocol (SwiftMapper `1.2.0`, named `Mapping`) used a single
/// `func map(_ input: Input) -> Output` requirement instead of a stored `input` + computed
/// `body`. It was reshaped into `Rule` to read closer to SwiftUI's own vocabulary. Two more
/// literal readings of "make it exactly like `View`" were considered and rejected along the
/// way:
///
/// - **A recursive `var body: some Rule { ... }`**, with sub-rules nested as values and
///   walked by a framework — this only works in real SwiftUI because the *runtime* privately
///   resolves `some View` via `_makeView`. Replicating that here means writing that walker
///   ourselves, which is exactly the kind of runtime combinator/engine this library's
///   [Non-goals](../../../README.md#non-goals) section already rejects.
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
/// - **No combinator operators.** `Rule` doesn't grow `.pullback`, `.map`, or any chaining
///   API — SwiftMapper's top-level Non-goals section already rejects a runtime combinator
///   library, and `Rule` doesn't change that.
/// - **No recursive `Rule`-typed `body` walked by a framework**, and **no ambient/
///   environment-style dependency resolution** — see Design history above. `Rule` is a
///   naming/shape convention, not a DI container or a rendering engine — the "no need to
///   inject it" ergonomics for a pure rule come entirely from a type having no stored
///   dependencies beyond its own `input`, not from a hidden lookup mechanism.
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
    var body: Output { get }
}
