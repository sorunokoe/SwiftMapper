/// The result builder that powers `Rule.body`, mirroring `@ViewBuilder var body: Body { get }`
/// on SwiftUI's `View`. It lets a `Rule`'s `body` read a child `Rule` directly — no `.body`,
/// no `Boxed()` wrapper — the same way a SwiftUI `body` reads a child `View` directly with no
/// separate "render" step:
///
/// ```swift
/// var body: InfoCardBarArrangement {
///     ScheduledInfoBannerRule(input: someInput)
/// }
/// ```
///
/// This only resolves a *single* level of `.body` per composed child — see
/// [Non-goals](Rule.swift) on `Rule` for why this deliberately stops short of a recursive,
/// tree-walking engine.
///
/// ## The one hard constraint: no explicit `return`
///
/// Swift only applies a result builder to a property's *entire* body when that body contains
/// **no explicit `return` statement anywhere** (this is a general Swift rule, not specific to
/// `RuleBuilder` — the same is true of `@ViewBuilder`). The moment a `body` contains a
/// `return` — including `guard ... else { return }` — Swift falls back to ordinary,
/// unsugared getter semantics for that entire property, and the existing `Boxed`-based
/// `.body`-free tricks (or plain `.body`) remain exactly as needed as before. This is why
/// `RuleBuilder` is purely additive: every `Rule` conformance that already compiles today
/// keeps compiling unchanged, whether or not it ever adopts the sugar.
///
/// In practice, this means `RuleBuilder` only pays off when a `Rule`'s *entire* output comes
/// from picking exactly one child rule (or plain value) per branch — a `switch` or `if`/`else`
/// used as the body's one expression, with no early-exit `guard`/`return` elsewhere:
///
/// ```swift
/// var body: TournamentLeaderboardFiltersData? {
///     switch onEnum(of: input.expandedInfo) {
///     case let .CourseRoundExpanded(courseRound):
///         CourseRoundLeaderboardFiltersRule(input: .init(expandedInfo: input.expandedInfo, courseRound: courseRound))
///     case .ClosestToPinExpanded, .LongestDriveExpanded:
///         LocationLeaderboardFiltersRule(input: input.expandedInfo)
///     default:
///         nil
///     }
/// }
/// ```
///
/// It does **not** help resolve a child rule's `body` used as an intermediate `let` binding,
/// or embedded as one argument among several in a larger struct literal — those aren't the
/// body's own tail expression, so the builder never sees them. Plain `.body` remains the
/// right, and only, tool there.
@resultBuilder
public enum RuleBuilder<Output> {
    /// A body whose one expression already produces `Output` directly (no child `Rule`
    /// involved) — passed through unchanged.
    public static func buildExpression(_ expression: Output) -> Output {
        expression
    }

    /// A body whose one expression constructs a child `Rule` matching `Output` — resolves its
    /// `body` for you, the same single, explicit, non-recursive read you'd otherwise write by
    /// hand as `.body`.
    public static func buildExpression<R: Rule>(_ rule: R) -> Output where R.Output == Output {
        rule.body
    }

    /// The same as the overload above, but for a `body` whose `Output` is `Optional` of a
    /// child rule's (non-optional) `Output` — e.g. one `switch` branch delegates to a rule
    /// producing `SomeData`, while `body` itself returns `SomeData?` (another branch
    /// contributing a bare `nil`). Swift's usual implicit-Optional-promotion (the same rule
    /// that lets `let x: Int? = condition ? 5 : nil` compile) doesn't automatically extend
    /// into a result builder's generic `buildExpression` — this overload restores it for the
    /// one case this library actually needs: an Optional-returning `Rule` composed from
    /// non-optional child rules.
    public static func buildExpression<R: Rule>(_ rule: R) -> Output where Output == R.Output? {
        rule.body
    }

    public static func buildBlock(_ component: Output) -> Output {
        component
    }

    /// Supports `if`/`else` and `switch` used as the body's one expression, where each branch
    /// independently resolves via one of the `buildExpression` overloads above.
    public static func buildEither(first component: Output) -> Output {
        component
    }

    /// Supports `if`/`else` and `switch` used as the body's one expression, where each branch
    /// independently resolves via one of the `buildExpression` overloads above.
    public static func buildEither(second component: Output) -> Output {
        component
    }
}
