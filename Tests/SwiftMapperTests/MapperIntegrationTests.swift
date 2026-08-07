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

// Global-actor-isolated escaping closure field support.
@Mapper
private struct MainActorClosureFieldData {
    let id: Int
    let render: @MainActor () -> Int

    init(id: Int, render: @MainActor @escaping () -> Int) {
        self.id = id
        self.render = render
    }
}

@Mapper
private struct WithDefaultValuedID: Identifiable, Equatable, Sendable {
    let id: Int = 42
    let value: String

    init(value: String) {
        self.value = value
    }
}

@Mapper
private struct HandWrittenEquatableWitness: Equatable {
    let id: Int
    let render: () -> Int

    init(id: Int, render: @escaping () -> Int) {
        self.id = id
        self.render = render
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

@Mapper
private final class PersonBox: Equatable {
    let firstName: String
    let lastName: String

    init(firstName: String, lastName: String) {
        self.firstName = firstName
        self.lastName = lastName
    }

    static func == (lhs: PersonBox, rhs: PersonBox) -> Bool {
        lhs.firstName == rhs.firstName && lhs.lastName == rhs.lastName
    }
}

// Exercises class support, generics, and auto-detection together: the
// memberwise-shaped designated initializer is picked automatically even
// though this class also declares a second, non-memberwise convenience
// initializer, with no @MapperCanonical marker needed.
@Mapper
private final class GenericBox<Value: Equatable>: Equatable {
    let label: String
    let value: Value

    init(label: String, value: Value) {
        self.label = label
        self.value = value
    }

    convenience init(value: Value) {
        self.init(label: "unlabeled", value: value)
    }

    static func == (lhs: GenericBox<Value>, rhs: GenericBox<Value>) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value
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

    @Test("Keyword initializer produces the same value as the canonical initializer")
    func keywordInitMatchesCanonicalInit() {
        let expected = PersonData(firstName: "Ada", lastName: "Lovelace", age: 36)

        let built = PersonData(
            firstName: { "Ada" },
            lastName: { "Lovelace" },
            age: { 36 }
        )

        #expect(built == expected)
    }

    @Test("Keyword initializer's labels must appear in the canonical initializer's declared order, like any Swift call")
    func keywordInitRequiresDeclarationOrder() {
        let built = PersonData(
            firstName: { "Ada" },
            lastName: { "Lovelace" },
            age: { 36 }
        )

        #expect(built == PersonData(firstName: "Ada", lastName: "Lovelace", age: 36))
    }

    @Test("Keyword initializer closures can run arbitrary mapping logic per field")
    func keywordInitClosuresRunArbitraryLogic() {
        let source = (first: "grace", last: "hopper", birthYear: 1906)
        let currentYear = 1943

        let built = PersonData(
            firstName: { source.first.capitalized },
            lastName: { source.last.capitalized },
            age: { currentYear - source.birthYear }
        )

        #expect(built == PersonData(firstName: "Grace", lastName: "Hopper", age: 37))
    }

    @Test("Keyword initializer fields built from a Rule need no .execute(), same as a Builder-DSL field")
    func keywordInitFieldFromRuleNeedsNoExecute() {
        struct UppercasedRule: Rule {
            let input: String

            var body: String { input.uppercased() }
        }

        // No `.execute()` — the keyword initializer's per-field
        // `@resultBuilder` resolves the child `Rule`'s `body` directly,
        // the same one-level resolution a `Builder`-DSL field already
        // gets from `Boxed`.
        let built = PersonData(
            firstName: { UppercasedRule(input: "ada") },
            lastName: { "Lovelace" },
            age: { 36 }
        )

        // `.execute()` still compiles too — it's just no longer required.
        let builtWithExecute = PersonData(
            firstName: { UppercasedRule(input: "ada").execute() },
            lastName: { "Lovelace" },
            age: { 36 }
        )

        #expect(built == PersonData(firstName: "ADA", lastName: "Lovelace", age: 36))
        #expect(built == builtWithExecute)
    }

    @Test("Keyword initializer supports an Optional field, including nil")
    func keywordInitOptionalFieldSupport() {
        let withNickname = NicknameData(
            firstName: { "Grace" },
            nickname: { "Amazing Grace" }
        )
        let withoutNickname = NicknameData(
            firstName: { "Grace" },
            nickname: { nil }
        )

        #expect(withNickname == NicknameData(firstName: "Grace", nickname: "Amazing Grace"))
        #expect(withoutNickname == NicknameData(firstName: "Grace", nickname: nil))
    }

    @Test("Keyword initializer supports generic structs with a single type parameter")
    func keywordInitGenericStructSupport() {
        let built = LabeledValue<Int>(
            label: { "count" },
            value: { 3 + 4 }
        )

        #expect(built == LabeledValue(label: "count", value: 7))
    }

    @Test("Keyword initializer supports classes via a generated convenience init")
    func keywordInitClassSupport() {
        let built = PersonBox(
            firstName: { "Ada" },
            lastName: { "Lovelace" }
        )

        #expect(built == PersonBox(firstName: "Ada", lastName: "Lovelace"))
    }

    @Test("Keyword and Builder-DSL initializers coexist on the same @Mapper type without conflict")
    func keywordInitCoexistsWithBuilderInit() {
        let viaBuilder = PersonData { FirstName, LastName, Age in
            FirstName { "Ada" }
            LastName { "Lovelace" }
            Age { 36 }
        }
        let viaKeyword = PersonData(
            firstName: { "Ada" },
            lastName: { "Lovelace" },
            age: { 36 }
        )
        let viaCanonical = PersonData(firstName: "Ada", lastName: "Lovelace", age: 36)

        #expect(viaBuilder == viaKeyword)
        #expect(viaKeyword == viaCanonical)
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

    @Test("Boxed(mapping:_:) composes an array field element-by-element from a per-element Rule, with no trailing .execute()")
    func collectionFieldElementWiseCompositionViaRule() {
        struct DomainItem {
            let name: String
        }

        struct CapitalizedTitleRule: Rule {
            let input: DomainItem

            var body: String {
                input.name.capitalized
            }
        }

        let domainItems = [DomainItem(name: "apple"), DomainItem(name: "bread")]

        let built = Cart { ItemTitles in
            ItemTitles(mapping: domainItems) { CapitalizedTitleRule(input: $0) }
        }

        #expect(built == Cart(itemTitles: ["Apple", "Bread"]))
    }

    @Test("Classes support the generated convenience builder initializer")
    func classBuilderSupport() {
        let built = PersonBox { FirstName, LastName in
            FirstName { "Ada" }
            LastName { "Lovelace" }
        }

        #expect(built == PersonBox(firstName: "Ada", lastName: "Lovelace"))
    }

    @Test("A stored let property with an in-place default value now compiles and works with @Mapper")
    func defaultValuedStoredPropertyNoLongerBreaksTheBuild() {
        let built = WithDefaultValuedID { Value in
            Value { "hello" }
        }

        #expect(built.id == 42)
        #expect(built.value == "hello")
    }

    @Test("A hand-written Equatable witness alongside @Mapper no longer triggers swiftlang/swift#70087")
    func handWrittenEquatableWitnessNoLongerConflicts() {
        let built = HandWrittenEquatableWitness { Id, Render in
            Id { 1 }
            Render { { 42 } }
        }

        #expect(built == HandWrittenEquatableWitness(id: 1, render: { 42 }))
    }

    @Test("A generic class with a non-memberwise convenience initializer still auto-detects its designated initializer")
    func genericClassWithAutoDetectionSupport() {
        let built = GenericBox<Int> { Label, Value in
            Label { "count" }
            Value { 42 }
        }

        #expect(built == GenericBox(label: "count", value: 42))
    }
}
