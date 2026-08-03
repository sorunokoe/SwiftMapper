import Testing

@testable import SwiftMapper

// A pure rule — no stored properties, constructed inline at each call site,
// mirroring `TournamentTypeToPresentationMapper` from the design note.
private struct UppercasingMapper: Mapping {
    func map(_ input: String) -> String {
        input.uppercased()
    }
}

// A context-needing rule — an explicit, constructor-injected collaborator,
// same shape as any other dependency-consuming mapper in this codebase.
private struct GreetingMapper: Mapping {
    struct Input {
        let name: String
        let isFormal: Bool
    }

    let salutationProvider: () -> String

    func map(_ input: Input) -> String {
        input.isFormal ? "\(salutationProvider()) \(input.name)" : "Hi \(input.name)"
    }
}

// A rule bundling a `Mapping` call inside an `@Mapper`-generated builder
// closure, demonstrating the two features compose without either requiring
// the other.
@Mapper
private struct PersonLabel: Equatable, Sendable {
    let name: String

    init(name: String) {
        self.name = name
    }
}

private struct PersonLabelMapper: Mapping {
    func map(_ input: String) -> PersonLabel {
        PersonLabel { Name in
            Name { UppercasingMapper().map(input) }
        }
    }
}

@Suite("Mapping protocol")
struct MappingTests {
    @Test("A pure Mapping conformance can be constructed inline with no stored properties")
    func pureMappingConstructedInline() {
        #expect(UppercasingMapper().map("ada") == "ADA")
    }

    @Test("A Mapping conformance with an injected collaborator behaves like any other mapper")
    func contextNeedingMappingUsesInjectedCollaborator() {
        let mapper = GreetingMapper(salutationProvider: { "Dr." })

        #expect(mapper.map(.init(name: "Hopper", isFormal: true)) == "Dr. Hopper")
        #expect(mapper.map(.init(name: "Hopper", isFormal: false)) == "Hi Hopper")
    }

    @Test("A Mapping rule composes with an @Mapper-generated builder initializer")
    func mappingComposesWithMapperBuilder() {
        #expect(PersonLabelMapper().map("grace") == PersonLabel(name: "GRACE"))
    }
}
