import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import SwiftMapperMacros

final class MapperMacroExpansionTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["Mapper": MapperMacro.self]

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
                    @ProfileHeaderDataBuilder
                    _ creation: (
                        _ Profile: Boxed<String>,
                        _ Fullname: Boxed<String>
                    ) -> Self
                ) {
                    self = creation(.init(), .init())
                }

                @resultBuilder
                public enum ProfileHeaderDataBuilder {
                    public static func buildBlock(_ profile: String, _ fullname: String) -> ProfileHeaderData {
                        ProfileHeaderData(profile: profile, fullname: fullname)
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
                    @NoteBuilder
                    _ creation: (
                        _ Text: Boxed<String>
                    ) -> Self
                ) {
                    self = creation(.init())
                }

                @resultBuilder
                enum NoteBuilder {
                    static func buildBlock(_ text: String) -> Note {
                        Note(text: text)
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
                    @ChartBuilder
                    _ creation: (
                        _ Render: Boxed<@MainActor () -> Int>
                    ) -> Self
                ) {
                    self = creation(.init())
                }

                @resultBuilder
                enum ChartBuilder {
                    static func buildBlock(_ render: @MainActor @escaping () -> Int) -> Chart {
                        Chart(render: render)
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

    func testWarnsAboutLikelyEquatableConformanceConflict() {
        assertMacroExpansion(
            """
            @Mapper
            struct Chart: Equatable {
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
            """,
            expandedSource: """
            struct Chart: Equatable {
                let id: Int
                let render: () -> Int

                init(id: Int, render: @escaping () -> Int) {
                    self.id = id
                    self.render = render
                }

                static func == (lhs: Self, rhs: Self) -> Bool {
                    lhs.id == rhs.id
                }

                init(
                    @ChartBuilder
                    _ creation: (
                        _ Id: Boxed<Int>,
                        _ Render: Boxed<() -> Int>
                    ) -> Self
                ) {
                    self = creation(.init(), .init())
                }

                @resultBuilder
                enum ChartBuilder {
                    static func buildBlock(_ id: Int, _ render: @escaping () -> Int) -> Chart {
                        Chart(id: id, render: render)
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
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    This struct declares its own '==' (or '<'/'hash(into:)') alongside a conformance \
                    that's normally auto-synthesized, which usually means a stored property (often a \
                    function-typed field) isn't itself Equatable/Hashable/Comparable. Combined with \
                    @Mapper, this can trigger a known Swift compiler bug where the compiler reports \
                    "type does not conform to protocol" / "multiple matching functions named '=='" even \
                    though the generated code is correct (swiftlang/swift#70087) — because @Mapper must \
                    declare `names: arbitrary`, which makes the compiler consider that it *might* \
                    generate '==' too. If you hit that error, this struct isn't a good fit for @Mapper \
                    until the upstream bug is fixed — keep it on a plain initializer instead.
                    """,
                    line: 1,
                    column: 1,
                    severity: .warning
                ),
            ],
            macros: macros
        )
    }

    func testDiagnosesDefaultValuedStoredProperty() {
        assertMacroExpansion(
            """
            @Mapper
            struct WithDefault: Identifiable {
                let id: UUID = .init()
                let value: String

                init(value: String) {
                    self.value = value
                }
            }
            """,
            expandedSource: """
            struct WithDefault: Identifiable {
                let id: UUID = .init()
                let value: String

                init(value: String) {
                    self.value = value
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                    @Mapper's generated builder initializer reassigns 'self' as a whole (`self = creation(...)`), \
                    which the Swift compiler cannot reconcile with a 'let' property that has an in-place default \
                    value here — it always reports "immutable value may only be initialized once", even though the \
                    property is never touched explicitly. This is a real Swift compiler limitation, not specific to \
                    @Mapper: remove the default value from the declaration (`let x: T`) and set it explicitly inside \
                    the canonical initializer's body instead (`self.x = <default>`), or change `let` to `var` if the \
                    property is meant to be mutable.
                    """,
                    line: 3,
                    column: 9
                ),
            ],
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
                    message: "@Mapper requires the struct to declare exactly one initializer whose parameters define the mapped fields",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }

    func testDiagnosesMultipleInitializers() {
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
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Mapper found more than one initializer; only a single canonical initializer is supported",
                    line: 9,
                    column: 5
                ),
                DiagnosticSpec(
                    message: "@Mapper found more than one initializer; only a single canonical initializer is supported",
                    line: 13,
                    column: 5
                ),
            ],
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

    func testDiagnosesNotAStruct() {
        assertMacroExpansion(
            """
            @Mapper
            class NotAStruct {
                init() {}
            }
            """,
            expandedSource: """
            class NotAStruct {
                init() {}
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Mapper can only be attached to a struct",
                    line: 1,
                    column: 1
                ),
            ],
            macros: macros
        )
    }
}
