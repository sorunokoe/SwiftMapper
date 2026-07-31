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
}
