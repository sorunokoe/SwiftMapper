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
///
/// `Boxed<T>` is `@frozen` because it is guaranteed to never gain a stored
/// property — its whole point is to carry no state — which lets it fully
/// optimize across module boundaries even in a library-evolution
/// (resilient) build: the compiler can see its (empty) layout and inline
/// through it instead of going through a resilient-witness call.
@frozen
public struct Boxed<T>: Sendable {
    @inlinable
    @inline(__always)
    public init() {}

    /// Invokes `creation` and returns its result. This is what allows a
    /// `Boxed<T>` value to be "called" like a function: `Profile { ... }`.
    ///
    /// Marked `@inline(__always)` (in addition to `@inlinable`) since this
    /// is a single-statement forwarding call executed once per mapped
    /// field: forcing inlining keeps it free of call overhead even in
    /// unoptimized (`-Onone`) debug builds, not only under `-O`.
    @inlinable
    @inline(__always)
    public func callAsFunction(_ creation: () -> T) -> T {
        creation()
    }
}
