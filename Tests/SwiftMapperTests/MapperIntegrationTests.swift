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

@Mapper
private struct DecodableLikeUser: Equatable, Sendable {
    let id: String
    let name: String

    @MapperCanonical
    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    // Simulates a second, non-canonical initializer a real struct might need
    // (e.g. a hand-written `Decodable.init(from:)`) that @Mapper must leave
    // untouched when a single other initializer is marked @MapperCanonical.
    init(fromLegacyID legacyID: Int, name: String) {
        self.id = "legacy-\(legacyID)"
        self.name = name
    }
}


@Mapper
private struct LabeledValue<Value: Equatable & Sendable>: Equatable, Sendable {
    let label: String
    let value: Value

    init(label: String, value: Value) {
        self.label = label
        self.value = value
    }
}

@Mapper
private struct Cart: Equatable, Sendable {
    let itemTitles: [String]

    init(itemTitles: [String]) {
        self.itemTitles = itemTitles
    }
}

@Mapper
private struct ConstrainedPair<Key, Value>: Equatable
    where Key: Hashable & Equatable, Value: Equatable
{
    let key: Key
    let value: Value

    init(key: Key, value: Value) {
        self.key = key
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

    @Test("Generic structs with a single type parameter support the builder initializer")
    func genericStructBuilderSupport() {
        let intValue = LabeledValue<Int> { Label, Value in
            Label { "count" }
            Value { 3 + 4 }
        }
        #expect(intValue == LabeledValue(label: "count", value: 7))

        let stringValue = LabeledValue<String> { Label, Value in
            Label { "name" }
            Value { "Ada".uppercased() }
        }
        #expect(stringValue == LabeledValue(label: "name", value: "ADA"))
    }

    @Test("Generic structs with multiple constrained type parameters and a where clause support the builder initializer")
    func constrainedGenericStructBuilderSupport() {
        let built = ConstrainedPair<String, Int> { Key, Value in
            Key { "answer" }
            Value { 42 }
        }

        #expect(built == ConstrainedPair(key: "answer", value: 42))
    }

    @Test("@MapperCanonical picks the marked initializer's fields, leaving other initializers untouched")
    func markedCanonicalInitializerBuilderSupport() {
        let built = DecodableLikeUser { Id, Name in
            Id { "abc123" }
            Name { "Ada" }
        }

        #expect(built == DecodableLikeUser(id: "abc123", name: "Ada"))

        // The non-canonical initializer still works normally; @Mapper never
        // touches it.
        let viaLegacy = DecodableLikeUser(fromLegacyID: 7, name: "Grace")
        #expect(viaLegacy == DecodableLikeUser(id: "legacy-7", name: "Grace"))
    }

    @Test("Boxed(mapping:_:) composes an array field element-by-element from a differently-typed source collection")
    func collectionFieldElementWiseComposition() {
        struct DomainItem {
            let name: String
        }

        let domainItems = [DomainItem(name: "apple"), DomainItem(name: "bread")]

        let built = Cart { ItemTitles in
            ItemTitles(mapping: domainItems) { $0.name.capitalized }
        }

        #expect(built == Cart(itemTitles: ["Apple", "Bread"]))
    }
}
