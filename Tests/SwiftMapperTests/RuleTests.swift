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

// A rule reading its `body` inside an `@Mapper`-generated builder closure, demonstrating the
// two features compose without either requiring the other.
@Mapper
private struct PersonLabel: Equatable, Sendable {
    let name: String

    init(name: String) {
        self.name = name
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
}
