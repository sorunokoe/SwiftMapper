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

        warnAboutLikelyEquatableConformanceConflict(in: structDecl, context: context)

        guard !diagnoseDefaultValuedStoredProperties(in: structDecl, context: context) else {
            return []
        }

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
                var fixIts: [FixIt] = []
                if let internalName = parameter.secondName {
                    let newParameter = parameter.with(
                        \.firstName,
                        internalName.trimmed.with(\.leadingTrivia, parameter.firstName.leadingTrivia)
                    )
                    fixIts.append(
                        FixIt(
                            message: UnlabeledParameterFixIt(newLabel: internalName.text),
                            changes: [.replace(oldNode: Syntax(parameter), newNode: Syntax(newParameter))]
                        )
                    )
                }
                context.diagnose(
                    Diagnostic(
                        node: Syntax(parameter),
                        message: MapperDiagnostic.unlabeledParameter,
                        fixIts: fixIts
                    )
                )
                return []
            }

            let boxedType = parameter.type.strippingParameterOnlyAnnotations.trimmedDescription
            let parameterType = parameter.type.strippingOwnershipSpecifiers.trimmedDescription
            fields.append(MapperField(label: label, boxedType: boxedType, parameterType: parameterType))
        }

        guard !fields.isEmpty else {
            context.diagnose(MapperDiagnostic.noFields.diagnose(at: canonicalInit))
            return []
        }

        let accessModifier = structDecl.modifiers.accessModifierPrefix
        let builderName = "\(typeName)Builder"

        let builderClosureParameters = fields
            .map { "        _ \($0.capitalizedLabel): Boxed<\($0.boxedType)>" }
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
            .map { "_ \($0.label): \($0.parameterType)" }
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

            \(accessModifier)static func buildBlock<Component>(_ component: Component) -> Component {
                component
            }

            \(accessModifier)static func buildEither<Component>(first component: Component) -> Component {
                component
            }

            \(accessModifier)static func buildEither<Component>(second component: Component) -> Component {
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
    /// The type used as `Boxed<T>`'s generic argument. Must not contain
    /// ownership specifiers or parameter-only attributes (`@escaping`,
    /// `@autoclosure`), since neither is valid in a generic-argument
    /// position (e.g. `Boxed<consuming String>` and
    /// `Boxed<@escaping () -> Void>` are both invalid Swift).
    let boxedType: String
    /// The type used for the generated `buildBlock`'s own parameter
    /// declaration. This *is* a real function parameter position, so it
    /// keeps `@escaping`/`@autoclosure` (needed to forward the value into
    /// the struct's escaping-requiring canonical initializer) while still
    /// dropping ownership specifiers, which the macro re-derives fresh
    /// rather than forwards.
    let parameterType: String

    var capitalizedLabel: String {
        label.prefix(1).uppercased() + label.dropFirst()
    }
}

/// Parameter-position-only type attributes: valid on a function parameter
/// declaration, but not as part of the type itself (e.g. not usable as a
/// generic argument like `Boxed<@escaping () -> Void>`, nor part of the
/// type of a stored property). These must always be dropped when the type
/// is used as a generic argument.
private let parameterOnlyAttributeNames: Set<String> = ["escaping", "autoclosure"]

private extension TypeSyntax {
    /// Strips ownership specifiers (`consuming`, `borrowing`, etc.) from a
    /// parameter's type while preserving every attribute, including
    /// parameter-only ones like `@escaping`. Ownership specifiers are only
    /// meaningful on a function parameter declaration, so they must not be
    /// forwarded into the generated `buildBlock`'s own parameter list
    /// (which has its own, independent ownership derived from the type).
    var strippingOwnershipSpecifiers: TypeSyntax {
        guard let attributed = self.as(AttributedTypeSyntax.self) else {
            return self
        }
        guard attributed.specifiers.isEmpty else {
            return TypeSyntax(attributed.with(\.specifiers, []))
        }
        return self
    }

    /// Strips ownership specifiers (`consuming`, `borrowing`, etc.) and
    /// parameter-only attributes (`@escaping`, `@autoclosure`) from a
    /// parameter's type, while preserving attributes that are genuinely part
    /// of the type itself (e.g. `@MainActor`, `@Sendable`, `@convention(_:)`).
    ///
    /// Ownership specifiers are only meaningful on a function parameter
    /// declaration — they cannot appear as a generic argument (e.g.
    /// `Boxed<consuming String>` is invalid Swift). Similarly, `@escaping`
    /// and `@autoclosure` only make sense annotating a parameter, not a
    /// standalone type — a stored property's function-typed field is
    /// implicitly escaping already. Global actors and other type-level
    /// attributes, however, must be kept: `let x: @MainActor () -> Void` is a
    /// real, distinct type from `() -> Void`, so dropping `@MainActor` would
    /// generate code that no longer type-checks against the original field.
    var strippingParameterOnlyAnnotations: TypeSyntax {
        guard let attributed = self.as(AttributedTypeSyntax.self) else {
            return self
        }

        let keptAttributes = attributed.attributes.filter { element in
            guard case let .attribute(attribute) = element,
                  let simpleName = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            else {
                return true
            }
            return !parameterOnlyAttributeNames.contains(simpleName)
        }

        guard !keptAttributes.isEmpty else {
            return attributed.baseType
        }

        let rebuilt = attributed
            .with(\.attributes, keptAttributes)
            .with(\.specifiers, [])
        return TypeSyntax(rebuilt)
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
    case likelyEquatableConformanceConflict
    case defaultValuedStoredProperty

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
            return "@Mapper requires every initializer parameter to have an explicit label; use the parameter's internal name as the label instead of '_'"
        case .noFields:
            return "@Mapper requires the initializer to declare at least one parameter"
        case .defaultValuedStoredProperty:
            return """
            @Mapper's generated builder initializer reassigns 'self' as a whole (`self = creation(...)`), \
            which the Swift compiler cannot reconcile with a 'let' property that has an in-place default \
            value here — it always reports "immutable value may only be initialized once", even though the \
            property is never touched explicitly. This is a real Swift compiler limitation, not specific to \
            @Mapper: remove the default value from the declaration (`let x: T`) and set it explicitly inside \
            the canonical initializer's body instead (`self.x = <default>`), or change `let` to `var` if the \
            property is meant to be mutable.
            """
        case .likelyEquatableConformanceConflict:
            return """
            This struct declares its own '==' (or '<'/'hash(into:)') alongside a conformance \
            that's normally auto-synthesized, which usually means a stored property (often a \
            function-typed field) isn't itself Equatable/Hashable/Comparable. Combined with \
            @Mapper, this can trigger a known Swift compiler bug where the compiler reports \
            "type does not conform to protocol" / "multiple matching functions named '=='" even \
            though the generated code is correct (swiftlang/swift#70087) — because @Mapper must \
            declare `names: arbitrary`, which makes the compiler consider that it *might* \
            generate '==' too. If you hit that error, this struct isn't a good fit for @Mapper \
            until the upstream bug is fixed — keep it on a plain initializer instead.
            """
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "SwiftMapper", id: rawValue)
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .likelyEquatableConformanceConflict:
            return .warning
        case .notAStruct, .missingInitializer, .multipleInitializers, .unsupportedParameter, .unlabeledParameter,
             .noFields, .defaultValuedStoredProperty:
            return .error
        }
    }

    func diagnose(at node: some SyntaxProtocol) -> Diagnostic {
        Diagnostic(node: Syntax(node), message: self)
    }
}

/// Best-effort, syntax-only heuristic for a known Swift compiler bug
/// (swiftlang/swift#70087): a member macro declaring `names: arbitrary`
/// makes the compiler consider that it *might* generate `==`/`<`/`hash(into:)`,
/// which conflicts with a hand-written one and produces a confusing
/// "does not conform to protocol" error — even though the macro's actual
/// expansion never touches those names. This can't be detected reliably
/// (macros only see syntax, not semantics), so it only warns when the
/// telltale shape is present: the struct declares `Equatable`, `Hashable`,
/// or `Comparable` *and* already hand-writes one of their witnesses (which
/// is normally unnecessary, since the compiler auto-synthesizes them).
private func warnAboutLikelyEquatableConformanceConflict(
    in structDecl: StructDeclSyntax,
    context: some MacroExpansionContext
) {
    let conformanceNames: Set<String> = ["Equatable", "Hashable", "Comparable"]
    let declaresRelevantConformance = structDecl.inheritanceClause?.inheritedTypes.contains { inherited in
        guard let name = inherited.type.as(IdentifierTypeSyntax.self)?.name.text else {
            return false
        }
        return conformanceNames.contains(name)
    } ?? false

    guard declaresRelevantConformance else {
        return
    }

    let declaresHandWrittenWitness = structDecl.memberBlock.members.contains { member in
        if let function = member.decl.as(FunctionDeclSyntax.self) {
            let name = function.name.text
            return name == "==" || name == "<" || name == "hash"
        }
        return false
    }

    guard declaresHandWrittenWitness else {
        return
    }

    context.diagnose(MapperDiagnostic.likelyEquatableConformanceConflict.diagnose(at: structDecl))
}

/// Detects a real, deterministic (not heuristic) Swift compiler limitation:
/// a stored `let` property declared with an in-place default value (e.g.
/// `let id: UUID = .init()`) can never be touched — explicitly or via a
/// whole-`self` reassignment — by any initializer other than the implicit
/// default-value prologue, or the compiler reports "immutable value may
/// only be initialized once". Since `@Mapper`'s generated builder init
/// always does `self = creation(...)`, any such property always breaks the
/// build. This is unrelated to macros in general (it reproduces with plain
/// hand-written structs too), so it's diagnosed as a hard error rather than
/// a best-effort warning. Returns `true` (and diagnoses) if the struct
/// cannot be expanded because of this.
private func diagnoseDefaultValuedStoredProperties(
    in structDecl: StructDeclSyntax,
    context: some MacroExpansionContext
) -> Bool {
    var foundOffendingProperty = false
    for member in structDecl.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              variable.bindingSpecifier.tokenKind == .keyword(.let)
        else {
            continue
        }

        for binding in variable.bindings where binding.initializer != nil {
            context.diagnose(MapperDiagnostic.defaultValuedStoredProperty.diagnose(at: binding))
            foundOffendingProperty = true
        }
    }
    return foundOffendingProperty
}

/// The Fix-It offered alongside `MapperDiagnostic.unlabeledParameter`: when
/// the parameter has an internal name (e.g. `_ profile: String`), the
/// overwhelmingly likely fix is to promote that internal name to also be
/// the external label — turning `_ profile: String` into
/// `profile profile: String`. If a parameter has no internal name either
/// (`_: String`), no mechanical fix exists, so no Fix-It is offered in that
/// case (see the call site in `MapperMacro.expansion(of:providingMembersOf:in:)`).
private struct UnlabeledParameterFixIt: FixItMessage {
    let newLabel: String

    var message: String { "Use '\(newLabel)' as the parameter's label" }

    var fixItID: MessageID {
        MessageID(domain: "SwiftMapper", id: "unlabeledParameter.useInternalName")
    }
}
