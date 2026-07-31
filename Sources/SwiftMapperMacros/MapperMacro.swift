import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Implements the `@Mapper` member macro. See `Mapper.swift` in the
/// `SwiftMapper` target for the full user-facing documentation and example.
public struct MapperMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(MapperDiagnostic.notAStruct.diagnose(at: declaration))
            return []
        }

        let typeName = structDecl.name.text

        let initializers = structDecl.memberBlock.members
            .compactMap { $0.decl.as(InitializerDeclSyntax.self) }

        guard let canonicalInit = initializers.first else {
            context.diagnose(MapperDiagnostic.missingInitializer.diagnose(at: structDecl))
            return []
        }

        guard initializers.count == 1 else {
            for extraInit in initializers.dropFirst() {
                context.diagnose(MapperDiagnostic.multipleInitializers.diagnose(at: extraInit))
            }
            return []
        }

        var fields: [MapperField] = []
        for parameter in canonicalInit.signature.parameterClause.parameters {
            guard parameter.ellipsis == nil else {
                context.diagnose(MapperDiagnostic.unsupportedParameter.diagnose(at: parameter))
                return []
            }

            let label = parameter.firstName.text
            guard label != "_" else {
                context.diagnose(MapperDiagnostic.unlabeledParameter.diagnose(at: parameter))
                return []
            }

            let type = parameter.type.trimmedDescription
            fields.append(MapperField(label: label, type: type))
        }

        guard !fields.isEmpty else {
            context.diagnose(MapperDiagnostic.noFields.diagnose(at: canonicalInit))
            return []
        }

        let accessModifier = structDecl.modifiers.accessModifierPrefix
        let builderName = "\(typeName)Builder"

        let builderClosureParameters = fields
            .map { "        _ \($0.capitalizedLabel): Boxed<\($0.type)>" }
            .joined(separator: ",\n")

        let creationArguments = fields.map { _ in ".init()" }.joined(separator: ", ")

        let builderInit = """
        \(accessModifier)init(
            @\(builderName)
            _ creation: (
        \(builderClosureParameters)
            ) -> Self
        ) {
            self = creation(\(creationArguments))
        }
        """

        let buildBlockParameters = fields
            .map { "_ \($0.label): \($0.type)" }
            .joined(separator: ", ")
        let buildBlockArguments = fields
            .map { "\($0.label): \($0.label)" }
            .joined(separator: ", ")

        let builderEnum = """
        @resultBuilder
        \(accessModifier)enum \(builderName) {
            \(accessModifier)static func buildBlock(\(buildBlockParameters)) -> \(typeName) {
                \(typeName)(\(buildBlockArguments))
            }

            \(accessModifier)static func buildEither<Component>(first component: Component) -> Component {
                component
            }

            \(accessModifier)static func buildEither<Component>(second component: Component) -> Component {
                component
            }

            \(accessModifier)static func buildOptional<Component>(_ component: Component?) -> Component? {
                component
            }
        }
        """

        return [
            DeclSyntax(stringLiteral: builderInit),
            DeclSyntax(stringLiteral: builderEnum),
        ]
    }
}

private struct MapperField {
    let label: String
    let type: String

    var capitalizedLabel: String {
        label.prefix(1).uppercased() + label.dropFirst()
    }
}

private extension DeclModifierListSyntax {
    /// Mirrors the struct's own access level onto generated members. Only
    /// `public` needs to be forwarded explicitly — `internal` (the default)
    /// requires no modifier, and the macro does not support wider access
    /// levels such as `open` on a struct.
    var accessModifierPrefix: String {
        contains { $0.name.tokenKind == .keyword(.public) } ? "public " : ""
    }
}

private enum MapperDiagnostic: String, DiagnosticMessage {
    case notAStruct
    case missingInitializer
    case multipleInitializers
    case unsupportedParameter
    case unlabeledParameter
    case noFields

    var message: String {
        switch self {
        case .notAStruct:
            return "@Mapper can only be attached to a struct"
        case .missingInitializer:
            return "@Mapper requires the struct to declare exactly one initializer whose parameters define the mapped fields"
        case .multipleInitializers:
            return "@Mapper found more than one initializer; only a single canonical initializer is supported"
        case .unsupportedParameter:
            return "@Mapper does not support variadic initializer parameters"
        case .unlabeledParameter:
            return "@Mapper requires every initializer parameter to have a label (no '_' parameters)"
        case .noFields:
            return "@Mapper requires the initializer to declare at least one parameter"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiftMapper", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }

    func diagnose(at node: some SyntaxProtocol) -> Diagnostic {
        Diagnostic(node: Syntax(node), message: self)
    }
}
