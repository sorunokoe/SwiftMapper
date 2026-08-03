/// A single, self-contained mapping rule — the `Mapping` equivalent of
/// SwiftUI's `View`.
///
/// `Mapping` has exactly one requirement, mirroring `View.body`: no
/// combinators, no environment, no ambient lookup. A conforming type is
/// either:
///
/// - A plain value type with **no stored properties** — a "pure" rule.
///   Construct it right where you use it, the same way `Text("x")` needs no
///   injection:
///
///   ```swift
///   struct TournamentTypeToPresentationMapper: Mapping {
///       func map(_ input: DomainTournamentType) -> TournamentType {
///           switch input {
///           case .bullsEye: .bullsEye
///           case .puttPutt: .puttPutt
///           // ...
///           }
///       }
///   }
///
///   // no DI, no registration — just call it:
///   TournamentType { TournamentTypeToPresentationMapper().map(domain.tournamentType) }
///   ```
///
/// - A type with **explicit, constructor-injected collaborators** when it
///   genuinely has some — the same pattern any other dependency-consuming
///   mapper already uses:
///
///   ```swift
///   struct TournamentInfoBannerToPresentationMapper: Mapping {
///       struct Input {
///           let eventStatus: DomainEventStatus
///           let playerPosition: DomainPlayerPosition
///       }
///
///       let placementBannerMapper: PlacementBannerToPresentationMapper
///       let scheduledToTagTextMapper: ScheduledStatusToTagTextPresentationMapper
///
///       func map(_ input: Input) -> InfoCardBarArrangement {
///           // ...
///       }
///   }
///   ```
///
/// ## Non-goals
///
/// - **No combinator operators.** `Mapping` doesn't grow `.pullback`,
///   `.map`, or any chaining API — SwiftMapper's top-level [Non-goals
///   section](../../../README.md#non-goals) already rejects a runtime
///   combinator library, and `Mapping` doesn't change that.
/// - **No ambient/environment-style dependency resolution.** Per
///   `CONTRIBUTING.md`, context/dependency parameters a mapping needs must
///   be threaded explicitly, not looked up ambiently or globally. `Mapping`
///   is a **naming/shape convention**, not a DI container — the "no need to
///   inject it" ergonomics for a pure rule come entirely from that type
///   having zero stored properties (there's nothing *to* inject), not from
///   a hidden lookup mechanism.
/// - **Not a replacement for `@Mapper`.** `@Mapper` generates a labeled
///   builder initializer for a struct with several fields; `Mapping` names
///   the shape of one small, single-input/single-output rule that a
///   `@Mapper`-generated builder closure (or any other call site) can call.
///   The two compose — a `Mapping` rule's `map(_:)` body is a perfectly
///   normal place to construct and call an `@Mapper`-annotated type's
///   builder initializer — but neither requires the other.
/// - **Not retrofitted onto every existing mapper.** `Mapping` is additive:
///   adopt it for new, genuinely single-input leaf rules. A mapper whose
///   natural shape takes several labeled parameters, or that dispatches
///   across a sealed type's cases before delegating to a specialized rule,
///   keeps that shape — bundle a small `Input` type only when it reads
///   better than the alternative.
public protocol Mapping<Input, Output> {
    associatedtype Input
    associatedtype Output

    /// Maps a single `Input` value to its `Output`. The one and only
    /// requirement — deliberately mirroring `View.body`.
    func map(_ input: Input) -> Output
}
