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
/// directly — `Boxed` reads its `body` for you, so no call site needs to write `.body`:
///
/// ```swift
/// DateBanner { TournamentInfoBannerRule(input: .init(eventStatus: status, playerPosition: position)) }
/// ```
///
/// You will not normally construct `Boxed<T>` yourself — the `@Mapper` macro
/// generates initializers that create one `Boxed<T>` per stored field and
/// pass them into your builder closure.
public struct Boxed<T>: Sendable {
    @inlinable
    public init() {}

    /// Invokes `creation` and returns its result. This is what allows a
    /// `Boxed<T>` value to be "called" like a function: `Profile { ... }`.
    @inlinable
    public func callAsFunction(_ creation: () -> T) -> T {
        creation()
    }

    /// Invokes `creation`, resolves the `Rule` it returns, and returns its `body` —
    /// the ergonomic equivalent of a SwiftUI renderer reading `View.body` for you.
    ///
    /// This is what lets a builder field read a `Rule` construction directly, with no
    /// trailing `.body`:
    ///
    /// ```swift
    /// // before — call the rule, then explicitly read its result:
    /// TournamentType { TournamentTypeRule(input: tournamentInfo.tournamentType).body }
    ///
    /// // after — construct the rule; `Boxed` reads `.body` for you:
    /// TournamentType { TournamentTypeRule(input: tournamentInfo.tournamentType) }
    /// ```
    ///
    /// This overload and the plain `() -> T` one above are never ambiguous: the trailing
    /// closure's return type is either a concrete `Output` value or a concrete `Rule`, never
    /// both, so overload resolution always has exactly one match. No tree-walking, no
    /// ambient lookup — this is a single, explicit, non-recursive `.body` read, the same one
    /// you'd otherwise write by hand.
    @inlinable
    public func callAsFunction<R: Rule>(_ creation: () -> R) -> T where R.Output == T {
        creation().body
    }
}

