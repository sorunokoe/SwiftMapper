import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import SwiftMapperMacros

final class MapperMacroExpansionTests: XCTestCase {
    private let macros: [String: Macro.Type] = [
        "Mapper": MapperMacro.self,
        "MapperCanonical": MapperCanonicalMacro.self,
    ]

    func testExpandsBuilderInitAndResultBuilder() {
        assertMacroExpansion(
            """
            @Mapper
            public struct ProfileHeaderData: Equatable {
                public let id: UUID
                public let profile: String
                public let fullname: String

                public init(profile: String, fullname: String) {
                    self.id = .init()
                    self.profile = profile
                    self.fullname = fullname
                }
            }
            """,
            expandedSource: """
            public struct ProfileHeaderData: Equatable {
                public let id: UUID
                public let profile: String
                public let fullname: String

                public init(profile: String, fullname: String) {
                    self.id = .init()
                    self.profile = profile
                    self.fullname = fullname
                }

                public init(
                    @Builder
                    _ creation: (
                        _ Profile: Boxed<String>,
                        _ Fullname: Boxed<String>
                    ) -> (String, String)
                ) {
                    let (profile, fullname) = creation(.init(), .init())
                    self.init(profile: profile, fullname: fullname)
                }

                @resultBuilder
                public enum Builder {
                    public static func buildBlock(_ profile: String, _ fullname: String) -> (String, String) {
                        (profile, fullname)
                    }

                    public static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    public static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    public static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testStripsOwnershipSpecifiersFromParameterTypes() {
        assertMacroExpansion(
            """
            @Mapper
            struct Note: Equatable {
                let text: String

                init(text: consuming String) {
                    self.text = text
                }
            }
            """,
            expandedSource: """
            struct Note: Equatable {
                let text: String

                init(text: consuming String) {
                    self.text = text
                }

                init(
                    @Builder
                    _ creation: (
                        _ Text: Boxed<String>
                    ) -> String
                ) {
                    let text = creation(.init())
                    self.init(text: text)
                }

                @resultBuilder
                enum Builder {
                    static func buildBlock(_ text: String) -> String {
                        text
                    }

                    static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testKeepsGlobalActorAttributeButStripsEscapingFromParameterTypes() {
        assertMacroExpansion(
            """
            @Mapper
            struct Chart: Equatable {
                let render: @MainActor () -> Int

                init(render: @MainActor @escaping () -> Int) {
                    self.render = render
                }
            }
            """,
            expandedSource: """
            struct Chart: Equatable {
                let render: @MainActor () -> Int

                init(render: @MainActor @escaping () -> Int) {
                    self.render = render
                }

                init(
                    @Builder
                    _ creation: (
                        _ Render: Boxed<@MainActor () -> Int>
                    ) -> @MainActor () -> Int
                ) {
                    let render = creation(.init())
                    self.init(render: render)
                }

                @resultBuilder
                enum Builder {
                    static func buildBlock(_ render: @MainActor @escaping () -> Int) -> @MainActor () -> Int {
                        render
                    }

                    static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testDiagnosesMissingInitializer() {
        assertMacroExpansion(
            """
            @Mapper
            struct NoInit {
                let value: String
            }
            """,
            expandedSource: """
            struct NoInit {
                let value: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Mapper requires the type to declare at least one initializer whose parameters define the mapped fields",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }

    func testAutoDetectsMemberwiseShapedInitializerWithoutMarker() {
        assertMacroExpansion(
            """
            @Mapper
            struct User: Decodable {
                let id: String
                let name: String

                init(id: String, name: String) {
                    self.id = id
                    self.name = name
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.id = try container.decode(String.self, forKey: .id)
                    self.name = try container.decode(String.self, forKey: .name)
                }
            }
            """,
            expandedSource: """
            struct User: Decodable {
                let id: String
                let name: String

                init(id: String, name: String) {
                    self.id = id
                    self.name = name
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.id = try container.decode(String.self, forKey: .id)
                    self.name = try container.decode(String.self, forKey: .name)
                }

                init(
                    @Builder
                    _ creation: (
                        _ Id: Boxed<String>,
                        _ Name: Boxed<String>
                    ) -> (String, String)
                ) {
                    let (id, name) = creation(.init(), .init())
                    self.init(id: id, name: name)
                }

                @resultBuilder
                enum Builder {
                    static func buildBlock(_ id: String, _ name: String) -> (String, String) {
                        (id, name)
                    }

                    static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testAutoDetectsSingleMemberwiseShapedInitializerAmongMany() {
        assertMacroExpansion(
            """
            @Mapper
            struct ThreeInits {
                let value: String

                init(value: String) {
                    self.value = value
                }

                init() {
                    self.value = ""
                }

                init(other: Int) {
                    self.value = "\\(other)"
                }
            }
            """,
            expandedSource: """
            struct ThreeInits {
                let value: String

                init(value: String) {
                    self.value = value
                }

                init() {
                    self.value = ""
                }

                init(other: Int) {
                    self.value = "\\(other)"
                }

                init(
                    @Builder
                    _ creation: (
                        _ Value: Boxed<String>
                    ) -> String
                ) {
                    let value = creation(.init())
                    self.init(value: value)
                }

                @resultBuilder
                enum Builder {
                    static func buildBlock(_ value: String) -> String {
                        value
                    }

                    static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testDiagnosesMultipleInitializersWhenNoneAreMemberwiseShaped() {
        assertMacroExpansion(
            """
            @Mapper
            struct AllConvenience {
                let value: String

                init(raw: String) {
                    self.value = raw
                }

                init(other: Int) {
                    self.value = "\\(other)"
                }
            }
            """,
            expandedSource: """
            struct AllConvenience {
                let value: String

                init(raw: String) {
                    self.value = raw
                }

                init(other: Int) {
                    self.value = "\\(other)"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    @Mapper found more than one initializer; mark exactly one of them @MapperCanonical to tell \
                    @Mapper which initializer's parameters define the mapped fields, or reduce the type to a \
                    single initializer
                    """,
                    line: 5,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Mark this initializer @MapperCanonical"),
                    ]
                ),
                DiagnosticSpec(
                    message: """
                    @Mapper found more than one initializer; mark exactly one of them @MapperCanonical to tell \
                    @Mapper which initializer's parameters define the mapped fields, or reduce the type to a \
                    single initializer
                    """,
                    line: 9,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Mark this initializer @MapperCanonical"),
                    ]
                ),
            ],
            macros: macros
        )
    }

    func testDiagnosesMultipleInitializersWhenAmbiguouslyMemberwiseShaped() {
        assertMacroExpansion(
            """
            @Mapper
            struct ReorderedPair {
                let a: String
                let b: String

                init(a: String, b: String) {
                    self.a = a
                    self.b = b
                }

                init(b: String, a: String) {
                    self.a = a
                    self.b = b
                }
            }
            """,
            expandedSource: """
            struct ReorderedPair {
                let a: String
                let b: String

                init(a: String, b: String) {
                    self.a = a
                    self.b = b
                }

                init(b: String, a: String) {
                    self.a = a
                    self.b = b
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    @Mapper found more than one initializer; mark exactly one of them @MapperCanonical to tell \
                    @Mapper which initializer's parameters define the mapped fields, or reduce the type to a \
                    single initializer
                    """,
                    line: 6,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Mark this initializer @MapperCanonical"),
                    ]
                ),
                DiagnosticSpec(
                    message: """
                    @Mapper found more than one initializer; mark exactly one of them @MapperCanonical to tell \
                    @Mapper which initializer's parameters define the mapped fields, or reduce the type to a \
                    single initializer
                    """,
                    line: 11,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Mark this initializer @MapperCanonical"),
                    ]
                ),
            ],
            macros: macros
        )
    }

    func testDiagnosesMultipleCanonicalInitializers() {
        assertMacroExpansion(
            """
            @Mapper
            struct TwoCanonical {
                let value: String

                @MapperCanonical
                init(value: String) {
                    self.value = value
                }

                @MapperCanonical
                init(other: Int) {
                    self.value = "\\(other)"
                }
            }
            """,
            expandedSource: """
            struct TwoCanonical {
                let value: String
                init(value: String) {
                    self.value = value
                }
                init(other: Int) {
                    self.value = "\\(other)"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Mapper found more than one initializer marked @MapperCanonical; only one is allowed per type",
                    line: 5,
                    column: 5
                ),
                DiagnosticSpec(
                    message: "@Mapper found more than one initializer marked @MapperCanonical; only one is allowed per type",
                    line: 10,
                    column: 5
                ),
            ],
            macros: macros
        )
    }

    func testExpandsBuilderInitUsingMarkedCanonicalInitializer() {
        assertMacroExpansion(
            """
            @Mapper
            struct User: Decodable {
                let id: String
                let name: String

                @MapperCanonical
                init(id: String, name: String) {
                    self.id = id
                    self.name = name
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.id = try container.decode(String.self, forKey: .id)
                    self.name = try container.decode(String.self, forKey: .name)
                }
            }
            """,
            expandedSource: """
            struct User: Decodable {
                let id: String
                let name: String
                init(id: String, name: String) {
                    self.id = id
                    self.name = name
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.id = try container.decode(String.self, forKey: .id)
                    self.name = try container.decode(String.self, forKey: .name)
                }

                init(
                    @Builder
                    _ creation: (
                        _ Id: Boxed<String>,
                        _ Name: Boxed<String>
                    ) -> (String, String)
                ) {
                    let (id, name) = creation(.init(), .init())
                    self.init(id: id, name: name)
                }

                @resultBuilder
                enum Builder {
                    static func buildBlock(_ id: String, _ name: String) -> (String, String) {
                        (id, name)
                    }

                    static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    /// `@Mapper`'s own attribute-matching logic (`isMarkedMapperCanonical`)
    /// recognizes both the bare (`@MapperCanonical`) and fully qualified
    /// (`@SwiftMapper.MapperCanonical`) spellings, so it still picks the
    /// marked initializer's fields either way. The test harness's own peer
    /// macro attribute-stripping (a separate, unrelated expansion pass) only
    /// matches attributes by their unqualified name, so unlike the bare
    /// spelling, the qualified attribute text itself is left in the
    /// `expandedSource` below rather than stripped, this is a harness detail
    /// and not something `@Mapper`'s own resolution depends on.
    func testRecognizesFullyQualifiedMapperCanonicalAttribute() {
        assertMacroExpansion(
            """
            @Mapper
            struct User: Decodable {
                let id: String
                let name: String

                @SwiftMapper.MapperCanonical
                init(id: String, name: String) {
                    self.id = id
                    self.name = name
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.id = try container.decode(String.self, forKey: .id)
                    self.name = try container.decode(String.self, forKey: .name)
                }
            }
            """,
            expandedSource: """
            struct User: Decodable {
                let id: String
                let name: String

                @SwiftMapper.MapperCanonical
                init(id: String, name: String) {
                    self.id = id
                    self.name = name
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.id = try container.decode(String.self, forKey: .id)
                    self.name = try container.decode(String.self, forKey: .name)
                }

                init(
                    @Builder
                    _ creation: (
                        _ Id: Boxed<String>,
                        _ Name: Boxed<String>
                    ) -> (String, String)
                ) {
                    let (id, name) = creation(.init(), .init())
                    self.init(id: id, name: name)
                }

                @resultBuilder
                enum Builder {
                    static func buildBlock(_ id: String, _ name: String) -> (String, String) {
                        (id, name)
                    }

                    static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testDiagnosesUnlabeledParameterWithFixIt() {
        assertMacroExpansion(
            """
            @Mapper
            struct Unlabeled {
                let value: String

                init(_ value: String) {
                    self.value = value
                }
            }
            """,
            expandedSource: """
            struct Unlabeled {
                let value: String

                init(_ value: String) {
                    self.value = value
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Mapper requires every initializer parameter to have an explicit label; use the parameter's internal name as the label instead of '_'",
                    line: 5,
                    column: 10,
                    fixIts: [
                        FixItSpec(message: "Use 'value' as the parameter's label"),
                    ]
                ),
            ],
            macros: macros
        )
    }

    func testExpandsBuilderInitForGenericStructWithWhereClause() {
        assertMacroExpansion(
            """
            @Mapper
            struct LabeledValue<Value>: Equatable where Value: Equatable {
                let label: String
                let value: Value

                init(label: String, value: Value) {
                    self.label = label
                    self.value = value
                }
            }
            """,
            expandedSource: """
            struct LabeledValue<Value>: Equatable where Value: Equatable {
                let label: String
                let value: Value

                init(label: String, value: Value) {
                    self.label = label
                    self.value = value
                }

                init(
                    @Builder
                    _ creation: (
                        _ Label: Boxed<String>,
                        _ Value: Boxed<Value>
                    ) -> (String, Value)
                ) {
                    let (label, value) = creation(.init(), .init())
                    self.init(label: label, value: value)
                }

                @resultBuilder
                enum Builder {
                    static func buildBlock(_ label: String, _ value: Value) -> (String, Value) {
                        (label, value)
                    }

                    static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testDiagnosesCollidingCapitalizedFieldLabels() {
        assertMacroExpansion(
            """
            @Mapper
            struct Confusing: Equatable {
                let name: String
                let Name: Int

                init(name: String, Name: Int) {
                    self.name = name
                    self.Name = Name
                }
            }
            """,
            expandedSource: """
            struct Confusing: Equatable {
                let name: String
                let Name: Int

                init(name: String, Name: Int) {
                    self.name = name
                    self.Name = Name
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    @Mapper capitalizes this parameter's label to 'Name' for the generated builder \
                    closure, but parameter 'name' already capitalizes to the same name — the \
                    generated builder initializer would end up with two parameters sharing that name. \
                    Rename one of the two initializer parameters so their capitalized builder labels \
                    don't collide.
                    """,
                    line: 6,
                    column: 24
                ),
            ],
            macros: macros
        )
    }

    func testExpandsConvenienceInitForClass() {
        assertMacroExpansion(
            """
            @Mapper
            final class Note: Equatable {
                let text: String

                init(text: String) {
                    self.text = text
                }

                static func == (lhs: Note, rhs: Note) -> Bool {
                    lhs.text == rhs.text
                }
            }
            """,
            expandedSource: """
            final class Note: Equatable {
                let text: String

                init(text: String) {
                    self.text = text
                }

                static func == (lhs: Note, rhs: Note) -> Bool {
                    lhs.text == rhs.text
                }

                convenience init(
                    @Builder
                    _ creation: (
                        _ Text: Boxed<String>
                    ) -> String
                ) {
                    let text = creation(.init())
                    self.init(text: text)
                }

                @resultBuilder
                enum Builder {
                    static func buildBlock(_ text: String) -> String {
                        text
                    }

                    static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    /// An `open` class is externally visible the same way a `public` one is
    /// (that's the whole point of `open`), so the generated `convenience
    /// init` and nested `Builder` enum must still be forwarded `public` —
    /// otherwise they'd be `internal` and invisible outside the module even
    /// though the class itself, and its canonical initializer, are usable
    /// from anywhere.
    func testExpandsPublicConvenienceInitForOpenClass() {
        assertMacroExpansion(
            """
            @Mapper
            open class Note {
                public let text: String

                public init(text: String) {
                    self.text = text
                }
            }
            """,
            expandedSource: """
            open class Note {
                public let text: String

                public init(text: String) {
                    self.text = text
                }

                public convenience init(
                    @Builder
                    _ creation: (
                        _ Text: Boxed<String>
                    ) -> String
                ) {
                    let text = creation(.init())
                    self.init(text: text)
                }

                @resultBuilder
                public enum Builder {
                    public static func buildBlock(_ text: String) -> String {
                        text
                    }

                    public static func buildBlock<Component>(_ component: Component) -> Component {
                        component
                    }

                    public static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    public static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }
                }
            }
            """,
            macros: macros
        )
    }

    func testDiagnosesExistingBuilderMemberCollision() {
        assertMacroExpansion(
            """
            @Mapper
            struct Confusing: Equatable {
                let value: String

                enum Builder {
                    case placeholder
                }

                init(value: String) {
                    self.value = value
                }
            }
            """,
            expandedSource: """
            struct Confusing: Equatable {
                let value: String

                enum Builder {
                    case placeholder
                }

                init(value: String) {
                    self.value = value
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    @Mapper needs to generate a nested type named 'Builder' on this type, but it already \
                    declares its own member named 'Builder'. Rename that member, or don't apply @Mapper to \
                    this type.
                    """,
                    line: 5,
                    column: 10
                ),
            ],
            macros: macros
        )
    }

    func testDiagnosesNotAStructOrClass() {
        assertMacroExpansion(
            """
            @Mapper
            enum NotAStructOrClass {
                case foo
            }
            """,
            expandedSource: """
            enum NotAStructOrClass {
                case foo
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Mapper can only be attached to a struct or class",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }
}
