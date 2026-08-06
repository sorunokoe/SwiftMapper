import Testing

@testable import SwiftMapper

// A pure rule — no stored properties beyond `input`, constructed inline at each call site,
// mirroring `TournamentTypeRule` from the design note.
private struct UppercasingRule: Rule {
    let input: String

    var body: String {
        input.uppercased()
    }
}

// A context-needing rule — an explicit, constructor-injected collaborator alongside `input`,
// same shape as any other dependency-consuming mapper in this codebase.
private struct GreetingRule: Rule {
    struct Input {
        let name: String
        let isFormal: Bool
    }

    let input: Input
    let salutationProvider: () -> String

    var body: String {
        input.isFormal ? "\(salutationProvider()) \(input.name)" : "Hi \(input.name)"
    }
}

// A rule whose Output another rule can be chained into via `execute(_:)`, mirroring
// the "count the uppercased word's length" kind of linear dependency a Mapper/Interactor
// composes today.
private struct WordLengthRule: Rule {
    let input: String

    var body: Int {
        input.count
    }
}

// A rule whose body chains `UppercasingRule` directly into `WordLengthRule` via
// `execute(_:)` — no intermediate `let` binding, no `.body` at either step.
private struct ChainedWordLengthRule: Rule {
    let input: String

    var body: Int {
        UppercasingRule(input: input).execute { uppercased in
            WordLengthRule(input: uppercased)
        }
    }
}

// A rule whose body chains `UppercasingRule` into a *plain value* (not another `Rule`) via
// the second continuation overload — the shape used to embed one rule's result as one piece
// of a larger literal.
private struct ChainedGreetingRule: Rule {
    let input: String

    var body: String {
        UppercasingRule(input: input).execute { uppercased in
            "HELLO, \(uppercased)!"
        }
    }
}

// A rule reading its `body` inside an `@Mapper`-generated builder closure, demonstrating the
// two features compose without either requiring the other.
@Mapper
private struct PersonLabel: Equatable, Sendable {
    let name: String

    init(name: String) {
        self.name = name
    }
}

// An `@Mapper` type with an Optional-typed field, resolved from a non-optional child `Rule` —
// exercises `Boxed`'s `Output == R.Output?` overloads (both the closure-taking and the
// bare-value one), the `Boxed` equivalent of `RuleBuilder`'s matching Optional overload.
@Mapper
private struct OptionalPersonLabel: Equatable, Sendable {
    let nickname: String?

    init(nickname: String?) {
        self.nickname = nickname
    }
}

private struct PersonLabelRule: Rule {
    let input: String

    var body: PersonLabel {
        PersonLabel { Name in
            Name { UppercasingRule(input: input).body }
        }
    }
}

// Same as `PersonLabelRule` above, but leaning on `Boxed`'s `Rule`-resolving `callAsFunction`
// overload instead of reading `.body` by hand — the two are equivalent.
private struct PersonLabelRuleWithoutExplicitBody: Rule {
    let input: String

    var body: PersonLabel {
        PersonLabel { Name in
            Name { UppercasingRule(input: input) }
        }
    }
}

// Same as `PersonLabelRuleWithoutExplicitBody` above, but the `@Mapper` field is
// Optional-typed while the rule it resolves to is non-optional — exercises `Boxed`'s
// `Output == R.Output?` closure-taking overload with a rule constructed inline.
private struct OptionalPersonLabelRule: Rule {
    let input: String

    var body: OptionalPersonLabel {
        OptionalPersonLabel { Nickname in
            Nickname { UppercasingRule(input: input) }
        }
    }
}

// Same as `OptionalPersonLabelRule` above, but passing an already-constructed `Rule` value —
// exercises `Boxed`'s `Output == R.Output?` bare-value overload.
private struct OptionalPersonLabelRuleWithConstructedRule: Rule {
    let input: String

    var body: OptionalPersonLabel {
        let rule = UppercasingRule(input: input)
        return OptionalPersonLabel { Nickname in
            Nickname(rule)
        }
    }
}

// Same as `PersonLabelRuleWithoutExplicitBody` above, but composing a child `Rule` directly
// inside its own `body` (no `@Mapper` builder field involved) via a throwaway `Boxed()`
// constructed on the spot — demonstrating the direct-value `callAsFunction` overload lets a
// `Rule`'s own `body` tail-delegate to a child rule with no explicit `.body`.
private struct ShoutingGreetingRule: Rule {
    let input: String

    var body: String {
        Boxed()(UppercasingRule(input: input))
    }
}

// Same as `ShoutingGreetingRule` above, but relying on `body`'s `@RuleBuilder<Output>` instead
// of a throwaway `Boxed()` — pure tail delegation to one child rule, with no `.body` and no
// `Boxed()` wrapper at all.
private struct DirectShoutingGreetingRule: Rule {
    let input: String

    var body: String {
        UppercasingRule(input: input)
    }
}

// A body that picks between two child rules (or a plain value) via `switch` used as the
// body's one expression — no `return` anywhere, so `@RuleBuilder<Output>` resolves each
// branch's `.body` for you.
private struct RoutingRule: Rule {
    enum Kind {
        case shout(String)
        case whisper(String)
        case silence
    }

    let input: Kind

    var body: String {
        switch input {
        case let .shout(text):
            UppercasingRule(input: text)
        case let .whisper(text):
            GreetingRule(input: .init(name: text, isFormal: true), salutationProvider: { "psst," })
        case .silence:
            ""
        }
    }
}

// A body whose Output is Optional of a non-optional child rule's Output, mixing a bare `nil`
// branch with a delegating-rule branch — exercises the `Output == R.Output?` buildExpression
// overload (Swift's usual implicit Optional-promotion doesn't reach into a result builder's
// generic buildExpression on its own).
private struct OptionalRoutingRule: Rule {
    enum Kind {
        case shout(String)
        case silence
    }

    let input: Kind

    var body: String? {
        switch input {
        case let .shout(text):
            UppercasingRule(input: text)
        case .silence:
            nil
        }
    }
}

// A rule whose `Output` is `[Int]`, built one line per array element — mixing two lines that
// each delegate to a child `Rule` producing `Int` with one line that's a plain `Int` value —
// exercising `RuleBuilder`'s array-specific `buildExpression`/`buildBlock` overloads (the
// "one row per line" shape, for a fixed, statically known set of rows written directly in
// `body`, rather than iterated at runtime).
private struct WordStatsRule: Rule {
    let input: String

    var body: [Int] {
        WordLengthRule(input: input)
        WordLengthRule(input: input.uppercased())
        input.count * 2
    }
}

// A body written in the pre-existing, return-heavy, explicit-`.body` style — proves that
// marking the protocol requirement `@RuleBuilder<Output>` doesn't force this style to change:
// any `return` anywhere in the property (including inside `guard`) falls back to ordinary,
// unsugared getter semantics for the whole property, exactly as it already did before
// `RuleBuilder` existed.
private struct ExistingStyleRule: Rule {
    let input: Int

    var body: String {
        guard input > 0 else { return "non-positive" }
        if input.isMultiple(of: 2) {
            return "even:\(UppercasingRule(input: "even").body)"
        }
        switch input {
        case 1:
            return "one"
        case 3:
            return "three"
        default:
            return "odd:\(input)"
        }
    }
}

@Suite("Rule protocol")
struct RuleTests {
    @Test("A pure Rule conformance can be constructed inline with no stored dependencies beyond input")
    func pureRuleConstructedInline() {
        #expect(UppercasingRule(input: "ada").body == "ADA")
    }

    @Test("A Rule conformance with an injected collaborator behaves like any other mapper")
    func contextNeedingRuleUsesInjectedCollaborator() {
        let formal = GreetingRule(input: .init(name: "Hopper", isFormal: true), salutationProvider: { "Dr." })
        let informal = GreetingRule(input: .init(name: "Hopper", isFormal: false), salutationProvider: { "Dr." })

        #expect(formal.body == "Dr. Hopper")
        #expect(informal.body == "Hi Hopper")
    }

    @Test("A Rule's body composes with an @Mapper-generated builder initializer")
    func ruleBodyComposesWithMapperBuilder() {
        #expect(PersonLabelRule(input: "grace").body == PersonLabel(name: "GRACE"))
    }

    @Test("Boxed resolves a Rule's body automatically, so a builder field needs no explicit .body")
    func boxedResolvesRuleBodyWithNoExplicitBody() {
        #expect(PersonLabelRuleWithoutExplicitBody(input: "grace").body == PersonLabel(name: "GRACE"))
    }

    @Test("Boxed resolves a non-optional child Rule into an Optional-typed @Mapper builder field")
    func boxedResolvesNonOptionalChildRuleIntoOptionalMapperField() {
        #expect(OptionalPersonLabelRule(input: "grace").body == OptionalPersonLabel(nickname: "GRACE"))
    }

    @Test("Boxed resolves an already-constructed non-optional Rule value into an Optional-typed @Mapper builder field")
    func boxedResolvesConstructedNonOptionalRuleValueIntoOptionalMapperField() {
        #expect(OptionalPersonLabelRuleWithConstructedRule(input: "grace").body == OptionalPersonLabel(nickname: "GRACE"))
    }

    @Test("A throwaway Boxed() resolves a child Rule's body with no explicit .body, outside a builder field")
    func boxedResolvesRuleValueDirectlyOutsideBuilderField() {
        #expect(ShoutingGreetingRule(input: "ada").body == "ADA")
    }

    @Test("body's @RuleBuilder resolves a child Rule's body with no .body and no Boxed() wrapper, for pure tail delegation")
    func ruleBuilderResolvesPureTailDelegationWithNoWrapper() {
        #expect(DirectShoutingGreetingRule(input: "ada").body == "ADA")
    }

    @Test("body's @RuleBuilder resolves each branch of a switch used as the body's one expression")
    func ruleBuilderResolvesSwitchBranchesMixingRulesAndPlainValues() {
        #expect(RoutingRule(input: .shout("ada")).body == "ADA")
        #expect(RoutingRule(input: .whisper("grace")).body == "psst, grace")
        #expect(RoutingRule(input: .silence).body == "")
    }

    @Test("body's @RuleBuilder resolves a non-optional child rule into an Optional-typed body")
    func ruleBuilderResolvesNonOptionalChildRuleIntoOptionalBody() {
        #expect(OptionalRoutingRule(input: .shout("ada")).body == "ADA")
        #expect(OptionalRoutingRule(input: .silence).body == nil)
    }

    @Test("execute() invokes a Rule and returns the same value as reading .body directly")
    func executeMatchesBody() {
        let rule = UppercasingRule(input: "ada")
        #expect(rule.execute() == rule.body)
        #expect(rule.execute() == "ADA")
    }

    @Test("execute() invokes a context-needing Rule the same way .body does")
    func executeMatchesBodyForContextNeedingRule() {
        let rule = GreetingRule(input: .init(name: "Hopper", isFormal: true), salutationProvider: { "Dr." })
        #expect(rule.execute() == rule.body)
        #expect(rule.execute() == "Dr. Hopper")
    }

    @Test("Chaining execute(_:) composes one Rule directly into another with no intermediate let binding")
    func chainingExecuteComposesTwoRules() {
        let chained = UppercasingRule(input: "ada").execute { uppercased in
            WordLengthRule(input: uppercased)
        }
        #expect(chained == 3)
        #expect(chained == WordLengthRule(input: "ADA").execute())
    }

    @Test("A Rule's own body can tail-delegate to a chained execute(_:) composition")
    func ruleBodyTailDelegatesToChainedComposition() {
        #expect(ChainedWordLengthRule(input: "grace").execute() == 5)
    }

    @Test("Chaining execute(_:) into a plain value composes one Rule's result directly into a larger expression with no intermediate let binding")
    func chainingExecuteComposesIntoAPlainValue() {
        let greeting = UppercasingRule(input: "ada").execute { uppercased in
            "HELLO, \(uppercased)!"
        }
        #expect(greeting == "HELLO, ADA!")
    }

    @Test("A Rule's own body can tail-delegate to a chained execute(_:) composition that produces a plain value")
    func ruleBodyTailDelegatesToChainedPlainValueComposition() {
        #expect(ChainedGreetingRule(input: "grace").execute() == "HELLO, GRACE!")
    }

    @Test("body's @RuleBuilder collects one array element per line, mixing child Rules and plain values, with no array literal or trailing () needed")
    func ruleBuilderCollectsArrayBodyOneElementPerLine() {
        #expect(WordStatsRule(input: "ada").body == [3, 3, 6])
    }

    @Test("An existing return-heavy, explicit-.body Rule still compiles and behaves correctly once body is @RuleBuilder<Output>")
    func returnHeavyBodyStaysBackwardCompatible() {
        #expect(ExistingStyleRule(input: -1).body == "non-positive")
        #expect(ExistingStyleRule(input: 2).body == "even:EVEN")
        #expect(ExistingStyleRule(input: 1).body == "one")
        #expect(ExistingStyleRule(input: 3).body == "three")
        #expect(ExistingStyleRule(input: 7).body == "odd:7")
    }
}
