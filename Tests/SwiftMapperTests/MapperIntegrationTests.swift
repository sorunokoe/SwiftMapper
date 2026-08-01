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

@Mapper
private struct NicknameData: Equatable, Sendable {
    let firstName: String
    let nickname: String?

    init(firstName: String, nickname: String?) {
        self.firstName = firstName
        self.nickname = nickname
    }
}

@Mapper
private struct ConsumingFieldData: Equatable, Sendable {
    let value: String

    init(value: consuming String) {
        self.value = value
    }
}

// Note: this struct intentionally does *not* conform to `Equatable`/`Sendable`
// with a hand-written witness. Doing so alongside `@Mapper` can trigger a
// known Swift compiler bug (swiftlang/swift#70087) where a member macro
// declaring `names: arbitrary` conflicts with a hand-written `==`/`hash(into:)`
// — see `MapperDiagnostic.likelyEquatableConformanceConflict` for the
// warning `@Mapper` emits when it detects this shape.
@Mapper
private struct MainActorClosureFieldData {
    let id: Int
    let render: @MainActor () -> Int

    init(id: Int, render: @MainActor @escaping () -> Int) {
        self.id = id
        self.render = render
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

    @Test("if/else can appear directly inside the builder closure")
    func ifElseBranchingInsideBuilderClosure() {
        func build(isSenior: Bool) -> PersonData {
            PersonData { FirstName, LastName, Age in
                FirstName { "Ada" }
                LastName { "Lovelace" }
                if isSenior {
                    Age { 90 }
                } else {
                    Age { 36 }
                }
            }
        }

        #expect(build(isSenior: true) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 90))
        #expect(build(isSenior: false) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 36))
    }

    @Test("switch can appear directly inside the builder closure")
    func switchBranchingInsideBuilderClosure() {
        enum Era {
            case victorian, modern, contemporary
        }

        func build(era: Era) -> PersonData {
            PersonData { FirstName, LastName, Age in
                FirstName { "Ada" }
                LastName { "Lovelace" }
                switch era {
                case .victorian:
                    Age { 36 }
                case .modern:
                    Age { 70 }
                case .contemporary:
                    Age { 100 }
                }
            }
        }

        #expect(build(era: .victorian) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 36))
        #expect(build(era: .modern) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 70))
        #expect(build(era: .contemporary) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 100))
    }

    @Test("if/else can appear directly inside the builder closure for an Optional field")
    func ifElseBranchingForOptionalField() {
        func build(hasNickname: Bool) -> NicknameData {
            NicknameData { FirstName, Nickname in
                FirstName { "Grace" }
                if hasNickname {
                    Nickname { "Amazing Grace" }
                } else {
                    Nickname { nil }
                }
            }
        }

        #expect(build(hasNickname: true) == NicknameData(firstName: "Grace", nickname: "Amazing Grace"))
        #expect(build(hasNickname: false) == NicknameData(firstName: "Grace", nickname: nil))
    }

    @Test("initializer parameters with ownership specifiers (consuming/borrowing) are supported")
    func consumingParameterSupport() {
        let built = ConsumingFieldData { Value in
            Value { "hello" }
        }

        #expect(built == ConsumingFieldData(value: "hello"))
    }

    @Test("Global-actor-isolated escaping closure fields keep their actor isolation")
    @MainActor
    func mainActorEscapingClosureFieldSupport() {
        let built = MainActorClosureFieldData { Id, Render in
            Id { 1 }
            Render { { 42 } }
        }

        #expect(built.id == 1)
        #expect(built.render() == 42)
    }
}
