import Testing

@testable import SwiftMapper

@Mapper
private struct PersonData: Equatable, Sendable {
    let firstName: String
    let lastName: String
    let age: Int

    init(firstName: String, lastName: String, age: Int) {
        self.firstName = firstName
        self.lastName = lastName
        self.age = age
    }
}

@Suite("Mapper macro integration")
struct MapperIntegrationTests {
    @Test("Builder initializer produces the same value as the canonical initializer")
    func builderMatchesCanonicalInit() {
        let expected = PersonData(firstName: "Ada", lastName: "Lovelace", age: 36)

        let built = PersonData { FirstName, LastName, Age in
            FirstName { "Ada" }
            LastName { "Lovelace" }
            Age { 36 }
        }

        #expect(built == expected)
    }

    @Test("Builder closures can run arbitrary mapping logic per field")
    func builderClosuresRunArbitraryLogic() {
        let source = (first: "grace", last: "hopper", birthYear: 1906)
        let currentYear = 1943

        let built = PersonData { FirstName, LastName, Age in
            FirstName { source.first.capitalized }
            LastName { source.last.capitalized }
            Age { currentYear - source.birthYear }
        }

        #expect(built == PersonData(firstName: "Grace", lastName: "Hopper", age: 37))
    }
}
