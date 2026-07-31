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

                    public static func buildEither<Component>(first component: Component) -> Component {
                        component
                    }

                    public static func buildEither<Component>(second component: Component) -> Component {
                        component
                    }

                    public static func buildOptional<Component>(_ component: Component?) -> Component? {
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
