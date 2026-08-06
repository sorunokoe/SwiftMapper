/// A labeled "slot" used inside a `@Mapper`-generated builder closure.
///
/// `Boxed<T>` carries no state of its own — its only job is to give each
/// positional parameter of a generated builder closure a readable name
/// (via Swift's closure-parameter autocomplete) while still deferring to a
/// plain `() -> T` closure for the actual value. This is what lets code like
///
/// ```swift
/// ProfileHeaderData { Profile, Fullname, Nickname in
///     Profile { .init(url: domain.avatarURL) }
///     Fullname { .loaded(domain.fullName) }
///     Nickname { domain.playerName }
/// }
/// ```
///
/// read like a small DSL: `Profile`, `Fullname`, and `Nickname` are each a
/// `Boxed<T>` value synthesized by the generated initializer, and calling
/// them (`Profile { ... }`) just runs the trailing closure to produce the
/// field's value.
///
/// When a field's value comes from a `Rule`, the trailing closure can construct the rule
/// directly — `Boxed` invokes it for you, so no call site needs to write `.body` or `.execute()`:
///
/// ```swift
/// DateBanner { TournamentInfoBannerRule(input: .init(eventStatus: status, playerPosition: position)) }
/// ```
///
/// You will not normally construct `Boxed<T>` yourself — the `@Mapper` macro generates
/// initializers that create one `Boxed<T>` per stored field and pass them into your builder
/// closure. Outside a builder field — e.g. inside a `Rule`'s own `body`, when it
/// tail-delegates to a child `Rule` but the surrounding code has an explicit `return` (which
/// disables `RuleBuilder`'s sugar; see `Rule`'s "Invoking a Rule" section) — call the child
/// rule directly instead of wrapping it in a throwaway `Boxed()`:
///
/// ```swift
/// var body: InfoCardBarArrangement {
///     // ...
///     return ScheduledInfoBannerRule(input: someInput).execute()
/// }
/// ```
public struct Boxed<T>: Sendable {
    @inlinable
    public init() {}

    /// Invokes `creation` and returns its result. This is what allows a
    /// `Boxed<T>` value to be "called" like a function: `Profile { ... }`.
    @inlinable
    public func callAsFunction(_ creation: () -> T) -> T {
        creation()
    }

    /// Invokes `creation`, then invokes the `Rule` it returns — the ergonomic equivalent of a
    /// SwiftUI renderer resolving a child `View` for you.
    ///
    /// This is what lets a builder field read a `Rule` construction directly, with no
    /// trailing `.execute()`:
    ///
    /// ```swift
    /// // equivalent — a builder field needs no trailing .execute() at all:
    /// TournamentType { TournamentTypeRule(input: tournamentInfo.tournamentType).execute() }
    /// TournamentType { TournamentTypeRule(input: tournamentInfo.tournamentType) }
    /// ```
    ///
    /// This overload and the plain `() -> T` one above are never ambiguous: the trailing
    /// closure's return type is either a concrete `Output` value or a concrete `Rule`, never
    /// both, so overload resolution always has exactly one match. No tree-walking, no
    /// ambient lookup — this is a single, explicit, non-recursive invocation, the same one
    /// you'd otherwise write by hand as `rule()`.
    @inlinable
    public func callAsFunction<R: Rule>(_ creation: () -> R) -> T where R.Output == T {
        creation().execute()
    }

    /// Resolves an already-constructed `Rule` value by invoking it directly — the same
    /// "no wrapper needed" ergonomic as the closure-taking overload above, but for call sites
    /// that already have a rule value in hand rather than constructing one inside a trailing
    /// closure.
    ///
    /// Never ambiguous with the two overloads above: a bare `Rule` value's type never
    /// matches a closure parameter type, so overload resolution always has exactly one
    /// match. Still no tree-walking, no ambient lookup — just a single, explicit,
    /// non-recursive invocation, equivalent to calling `rule()` directly.
    @inlinable
    public func callAsFunction<R: Rule>(_ rule: R) -> T where R.Output == T {
        rule.execute()
    }

    /// The same as the closure-taking overload above, but for an `Optional`-typed field whose
    /// value comes from a non-optional `Rule` — e.g. `@Mapper` generates a
    /// `ParsScoresChart { ProfileMetricsParsScoresChartRule(input: ...) }` field where the
    /// stored property is `ProfileMetricsParsScoresChart?` but the rule's own `Output` is the
    /// non-optional `ProfileMetricsParsScoresChart`. Swift's usual implicit-Optional-promotion
    /// doesn't automatically extend into a generic function's return type — this overload
    /// restores it here the same way `RuleBuilder`'s matching overload restores it for a
    /// `Rule`'s own `body`.
    @inlinable
    public func callAsFunction<R: Rule>(_ creation: () -> R) -> T where T == R.Output? {
        creation().execute()
    }

    /// The same as the bare-value overload above, but for an `Optional`-typed field resolved
    /// from an already-constructed, non-optional `Rule` value.
    @inlinable
    public func callAsFunction<R: Rule>(_ rule: R) -> T where T == R.Output? {
        rule.execute()
    }
}

