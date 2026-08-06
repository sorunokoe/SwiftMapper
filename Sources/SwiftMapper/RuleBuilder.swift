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
/// It does **not** help resolve a child rule's result used as an intermediate `let` binding,
/// or embedded as one argument among several in a larger struct literal — those aren't the
/// body's own tail expression, so the builder never sees them. Calling the rule directly
/// (`rule.execute()`) remains the right, and only, tool there — see `Rule`'s "Invoking a Rule" section
/// for why that's preferred over reading `.body`.
@resultBuilder
public enum RuleBuilder<Output> {
    /// A body whose one expression already produces `Output` directly (no child `Rule`
    /// involved) — passed through unchanged.
    public static func buildExpression(_ expression: Output) -> Output {
        expression
    }

    /// A body whose one expression constructs a child `Rule` matching `Output` — invokes it
    /// for you, the same single, explicit, non-recursive call you'd otherwise write by hand as
    /// `rule.execute()`.
    public static func buildExpression<R: Rule>(_ rule: R) -> Output where R.Output == Output {
        rule.execute()
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
        rule.execute()
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

extension RuleBuilder {
    /// Supports a body whose `Output` is `[Element]`, built from one line per array element —
    /// the same "one row per line" shape `ForEach`'s content closure has, but for a fixed,
    /// statically known set of rows written directly in `body` rather than iterated at
    /// runtime:
    ///
    /// ```swift
    /// var body: [DataState<TournamentSettingsItemData>] {
    ///     TournamentSettingsAttemptsRule(input: input.attempts)
    ///     TournamentSettingsGameNameRule(input: input.courseName)
    ///     TournamentSettingsHolesRule(input: input.puttPuttTournament.numberOfHoles)
    /// }
    /// ```
    ///
    /// Each line is either a plain `Element` value (this overload) or a child `Rule`
    /// producing `Element` (the next overload below) — resolved the same single,
    /// non-recursive way as every other `RuleBuilder` overload. The classic array-literal
    /// form (`[a(), b(), c()]`) remains exactly as valid as before — it hits the plain
    /// `Output`-typed overloads above unchanged — this is additive sugar, not a replacement.
    public static func buildExpression<Element>(_ expression: Element) -> Element where Output == [Element] {
        expression
    }

    /// The `Rule`-producing counterpart of the overload above: one line constructs a child
    /// `Rule` whose `Output` matches one array element — invoked for you, same as every other
    /// `RuleBuilder` overload.
    public static func buildExpression<R: Rule, Element>(_ rule: R) -> Element where Output == [Element], R.Output == Element {
        rule.execute()
    }

    /// Collects one `Element` per `body` line into the final `[Element]` array.
    public static func buildBlock<Element>(_ components: Element...) -> [Element] where Output == [Element] {
        components
    }
}
