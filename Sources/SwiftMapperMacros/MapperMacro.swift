import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// The two declaration kinds `@Mapper` can attach to. Both `StructDeclSyntax`
/// and `ClassDeclSyntax` expose everything the rest of this macro needs
/// (`name`, `memberBlock`, `modifiers`, `inheritanceClause`) but don't share
/// a protocol that exposes all of those, so this wraps whichever one was
/// actually attached and forwards the handful of members `expansion` reads.
private enum MapperTarget {
    case structDecl(StructDeclSyntax)
    case classDecl(ClassDeclSyntax)

    init?(_ declaration: some DeclGroupSyntax) {
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            self = .structDecl(structDecl)
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            self = .classDecl(classDecl)
        } else {
            return nil
        }
    }

    var name: TokenSyntax {
        switch self {
        case let .structDecl(decl): return decl.name
        case let .classDecl(decl): return decl.name
        }
    }

    var memberBlock: MemberBlockSyntax {
        switch self {
        case let .structDecl(decl): return decl.memberBlock
        case let .classDecl(decl): return decl.memberBlock
        }
    }

    var modifiers: DeclModifierListSyntax {
        switch self {
        case let .structDecl(decl): return decl.modifiers
        case let .classDecl(decl): return decl.modifiers
        }
    }

    var inheritanceClause: InheritanceClauseSyntax? {
        switch self {
        case let .structDecl(decl): return decl.inheritanceClause
        case let .classDecl(decl): return decl.inheritanceClause
        }
    }

    /// Whether this target is a class — the generated initializer must be
    /// `convenience` for classes and a plain `init` for structs.
    var isClass: Bool {
        if case .classDecl = self { return true }
        return false
    }

    /// The underlying declaration as `Syntax`, for diagnosing at the whole
    /// declaration (matching where `@Mapper`'s own diagnostics have always
    /// pointed — the same location `declaration` itself would use).
    var syntax: Syntax {
        switch self {
        case let .structDecl(decl): return Syntax(decl)
        case let .classDecl(decl): return Syntax(decl)
        }
    }
}

/// Implements the `@Mapper` member macro. See `Mapper.swift` in the
/// `SwiftMapper` target for the full user-facing documentation and example.
public struct MapperMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let target = MapperTarget(declaration) else {
            context.diagnose(MapperDiagnostic.notAStructOrClass.diagnose(at: declaration))
            return []
        }

        if let collidingMember = findExistingBuilderMemberCollision(in: target) {
            context.diagnose(MapperDiagnostic.existingBuilderMemberCollision.diagnose(at: collidingMember))
            return []
        }

        let initializers = target.memberBlock.members
            .compactMap { $0.decl.as(InitializerDeclSyntax.self) }

        guard !initializers.isEmpty else {
            context.diagnose(MapperDiagnostic.missingInitializer.diagnose(at: target.syntax))
            return []
        }

        guard let canonicalInit = resolveCanonicalInitializer(among: initializers, target: target, context: context) else {
            return []
        }

        var fields: [MapperField] = []
        var seenCapitalizedLabels: [String: TokenSyntax] = [:]
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

            let field = MapperField(
                label: label,
                boxedType: parameter.type.strippingParameterOnlyAnnotations,
                parameterType: parameter.type.strippingOwnershipSpecifiers
            )

            if let firstLabel = seenCapitalizedLabels[field.capitalizedLabel] {
                context.diagnose(
                    MapperDiagnostic.collidingCapitalizedFieldLabels(
                        capitalizedLabel: field.capitalizedLabel,
                        otherParameterLabel: firstLabel.text
                    )
                    .diagnose(at: parameter.firstName)
                )
                return []
            }
            seenCapitalizedLabels[field.capitalizedLabel] = parameter.firstName

            fields.append(field)
        }

        guard !fields.isEmpty else {
            context.diagnose(MapperDiagnostic.noFields.diagnose(at: canonicalInit))
            return []
        }

        guard fields.count <= keywordFieldBuilderMaxFieldCount else {
            context.diagnose(
                MapperDiagnostic.tooManyFieldsForKeywordInit(
                    fieldCount: fields.count,
                    maxFieldCount: keywordFieldBuilderMaxFieldCount
                )
                .diagnose(at: canonicalInit)
            )
            return []
        }

        // All generated members are built as real, already-typed
        // `SwiftSyntax` nodes end-to-end — never through
        // `DeclSyntax(stringLiteral:)`/string interpolation — so expanding
        // `@Mapper` never re-parses source text, no matter how many fields
        // or how complex their types are. See `makeBuilderInit`/
        // `keywordFieldBuilderTypealiasDecls`/`makeKeywordInit`/
        // `makeBuilderEnum` below.
        return [
            DeclSyntax(makeBuilderInit(target: target, fields: fields)),
        ] + keywordFieldBuilderTypealiasDecls(for: fields) + [
            DeclSyntax(makeKeywordInit(target: target, fields: fields)),
            DeclSyntax(makeBuilderEnum(target: target, fields: fields)),
        ]
    }
}

/// Builds the generated `init(@Builder _ creation: (...) -> ...)` —
/// `convenience init` for classes, plain `init` for structs — entirely out
/// of typed `SwiftSyntax` nodes. A handful of explicit `.newline` trivia
/// (never full re-parsed text) reproduce the same multi-line, readable
/// layout the previous string-template implementation produced; everything
/// else about indentation is normalized afterwards by the macro-expansion
/// pipeline's `BasicFormat` pass.
private func makeBuilderInit(target: MapperTarget, fields: [MapperField]) -> InitializerDeclSyntax {
    var modifiers = target.modifiers.mirroredForGeneratedMembers
    if target.isClass {
        modifiers = modifiers + [DeclModifierSyntax(name: .keyword(.convenience))]
    }

    let creationParameter = FunctionParameterSyntax(
        attributes: AttributeListSyntax {
            AttributeSyntax(
                attributeName: IdentifierTypeSyntax(name: .identifier("Builder")),
                trailingTrivia: .newline
            )
        },
        firstName: .wildcardToken(),
        secondName: .identifier("creation"),
        type: FunctionTypeSyntax(
            leftParen: .leftParenToken(trailingTrivia: .newline),
            parameters: creationClosureParameterList(for: fields),
            returnClause: ReturnClauseSyntax(type: combinedBoxedType(of: fields))
        ),
        trailingTrivia: .newline
    )

    return InitializerDeclSyntax(
        modifiers: modifiers,
        signature: FunctionSignatureSyntax(
            parameterClause: FunctionParameterClauseSyntax(
                leftParen: .leftParenToken(trailingTrivia: .newline),
                parameters: FunctionParameterListSyntax { creationParameter }
            )
        ),
        body: CodeBlockSyntax {
            creationBindingDecl(for: fields)
            delegatingSelfInitCallExpr(for: fields)
        }
    )
}

/// Builds the generated flat, labeled "keyword" initializer — `convenience
/// init` for classes, plain `init` for structs — entirely out of typed
/// `SwiftSyntax` nodes. Unlike `makeBuilderInit`'s single `@Builder`
/// closure, this initializer takes one ordinary, independently labeled
/// closure per field (same labels, order, and types as the canonical
/// initializer), so callers can write:
///
/// ```swift
/// Address(
///     street: { rawInput.line1 },
///     city: { rawInput.city.capitalized },
///     postalCode: { rawInput.zip.trimmed() }
/// )
/// ```
///
/// instead of opening the `Builder`-DSL block. Each field's closure is
/// marked `@RuleBuilder<FieldType>` (via a private, per-field typealias —
/// see `keywordFieldBuilderTypealiasDecls` — since an attribute can't carry
/// explicit generic arguments directly), so a field built from a `Rule`
/// needs no `.execute()` here either: `RuleBuilder`'s own
/// `buildExpression` overloads resolve a plain value or a child `Rule`
/// independently for *this one field's* closure, the same one-level
/// resolution `Rule.body` already gets. Each field is still an
/// independently type-checked argument — result-builder resolution is
/// purely per-closure, so there's no combinatorial blow-up across fields
/// no matter how many of them mix plain values and rules.
private func makeKeywordInit(target: MapperTarget, fields: [MapperField]) -> InitializerDeclSyntax {
    var modifiers = target.modifiers.mirroredForGeneratedMembers
    if target.isClass {
        modifiers = modifiers + [DeclModifierSyntax(name: .keyword(.convenience))]
    }

    return InitializerDeclSyntax(
        modifiers: modifiers,
        signature: FunctionSignatureSyntax(
            parameterClause: FunctionParameterClauseSyntax(
                leftParen: .leftParenToken(trailingTrivia: .newline),
                parameters: keywordParameterList(for: fields)
            )
        ),
        body: CodeBlockSyntax {
            keywordDelegatingSelfInitCallExpr(for: fields)
        }
    )
}

/// The fixed number of `__MapperFieldBuilderN` typealiases `@Mapper`
/// declares as its own `@attached(member, names: ...)` member names (see
/// `Mapper.swift`) — and therefore the hard upper bound on how many fields
/// the generated keyword initializer can cover. Deliberately generous
/// (comfortably above any real-world initializer's field count) without
/// being unbounded.
///
/// This is a **fixed, statically-named** list rather than
/// `names: arbitrary` on purpose: attaching a member macro with
/// `names: arbitrary` to a type that also declares its own hand-written
/// operator (`==`, `<`, etc. — e.g. a hand-rolled `Equatable`/`Comparable`
/// conformance) can trip a known Swift compiler bug
/// (https://github.com/swiftlang/swift/issues/70087) where the compiler
/// reports the hand-written operator as colliding with itself
/// ("multiple matching functions named '=='"), even though the macro never
/// actually generates that operator. Declaring a fixed, explicitly-named
/// set of possible members up front avoids `arbitrary` (and that bug)
/// entirely, at the cost of a hard cap on field count.
private let keywordFieldBuilderMaxFieldCount = 32

/// The private, per-position name used both by
/// `keywordFieldBuilderTypealiasDecls` (declaring
/// `typealias __MapperFieldBuilderN = RuleBuilder<FieldType>`) and
/// `keywordParameterList` (attaching `@__MapperFieldBuilderN` to that
/// field's closure parameter). Named by the field's *position* in the
/// canonical initializer's parameter list, not by its label — the macro
/// declares a fixed set of `__MapperFieldBuilder0 ... __MapperFieldBuilderN`
/// names up front (see `keywordFieldBuilderMaxFieldCount`), so the name a
/// given field gets must be predictable purely from its index, not from
/// text that's only known once the macro actually expands.
private func keywordFieldBuilderTypealiasName(at index: Int) -> String {
    "__MapperFieldBuilder\(index)"
}

/// One `private typealias __MapperFieldBuilderN = RuleBuilder<FieldType>`
/// per field (named by position — see `keywordFieldBuilderTypealiasName`) —
/// a generic `@resultBuilder` type can't be referenced with explicit
/// generic arguments directly in attribute position (Swift doesn't allow
/// `@RuleBuilder<String>`), so each field gets its own concrete,
/// non-generic alias to attach as `@__MapperFieldBuilderN` instead.
/// `private` regardless of the type's own access level: these aliases are
/// pure internal plumbing for the keyword initializer's own parameter
/// attributes, never meant to be referenced from outside the type.
private func keywordFieldBuilderTypealiasDecls(for fields: [MapperField]) -> [DeclSyntax] {
    fields.enumerated().map { index, field in
        DeclSyntax(
            TypeAliasDeclSyntax(
                modifiers: DeclModifierListSyntax {
                    DeclModifierSyntax(name: .keyword(.private))
                },
                name: .identifier(keywordFieldBuilderTypealiasName(at: index)),
                initializer: TypeInitializerClauseSyntax(
                    value: IdentifierTypeSyntax(
                        name: .identifier("RuleBuilder"),
                        genericArgumentClause: GenericArgumentClauseSyntax(
                            arguments: GenericArgumentListSyntax {
                                GenericArgumentSyntax(argument: .type(field.boxedType))
                            }
                        )
                    )
                )
            )
        )
    }
}

/// The keyword initializer's own parameter list, e.g.
/// `@__MapperFieldBuilder0 street: () -> String` — one closure per field,
/// each on its own line (matching the builder initializer's layout),
/// marked with its own per-position `RuleBuilder` typealias so a plain
/// value or a child `Rule` both resolve with no `.execute()`.
private func keywordParameterList(for fields: [MapperField]) -> FunctionParameterListSyntax {
    FunctionParameterListSyntax(
        fields.enumerated().map { index, field in
            let isLast = index == fields.count - 1
            return FunctionParameterSyntax(
                attributes: AttributeListSyntax {
                    AttributeSyntax(
                        attributeName: IdentifierTypeSyntax(
                            name: .identifier(keywordFieldBuilderTypealiasName(at: index))
                        ),
                        trailingTrivia: .space
                    )
                },
                firstName: .identifier(field.label),
                colon: .colonToken(),
                type: FunctionTypeSyntax(
                    parameters: TupleTypeElementListSyntax { },
                    returnClause: ReturnClauseSyntax(type: field.boxedType)
                ),
                trailingComma: isLast ? nil : .commaToken(),
                trailingTrivia: .newline
            )
        }
    )
}

/// `self.init(street: street(), city: city())` — the delegating call that
/// invokes each keyword closure and forwards its result to the canonical
/// initializer.
private func keywordDelegatingSelfInitCallExpr(for fields: [MapperField]) -> FunctionCallExprSyntax {
    FunctionCallExprSyntax(
        calledExpression: MemberAccessExprSyntax(
            base: DeclReferenceExprSyntax(baseName: .keyword(.`self`)),
            declName: DeclReferenceExprSyntax(baseName: .keyword(.`init`))
        ),
        leftParen: .leftParenToken(),
        arguments: LabeledExprListSyntax {
            for field in fields {
                LabeledExprSyntax(
                    label: .identifier(field.label),
                    colon: .colonToken(),
                    expression: FunctionCallExprSyntax(
                        calledExpression: DeclReferenceExprSyntax(baseName: .identifier(field.label)),
                        leftParen: .leftParenToken(),
                        arguments: [],
                        rightParen: .rightParenToken()
                    )
                )
            }
        },
        rightParen: .rightParenToken()
    )
}

/// Builds the generated `@resultBuilder enum Builder { ... }`, containing
/// the field-shaped `buildBlock` plus the three fixed generic helpers
/// (`buildBlock<Component>`, `buildEither(first:)`, `buildEither(second:)`),
/// entirely out of typed `SwiftSyntax` nodes.
private func makeBuilderEnum(target: MapperTarget, fields: [MapperField]) -> EnumDeclSyntax {
    let modifiers = target.modifiers.mirroredForGeneratedMembers
    let staticModifiers = modifiers + [DeclModifierSyntax(name: .keyword(.static))]

    // A blank line between each member, matching the previous string
    // template's layout — every member after the first gets a two-newline
    // leading trivia (blank line + the line it starts on).
    let blankLineBeforeMember = Trivia.newlines(2)

    return EnumDeclSyntax(
        attributes: AttributeListSyntax {
            AttributeSyntax(
                attributeName: IdentifierTypeSyntax(name: .identifier("resultBuilder")),
                trailingTrivia: .newline
            )
        },
        modifiers: modifiers,
        name: .identifier("Builder"),
        memberBlock: MemberBlockSyntax {
            fieldBuildBlockFunc(modifiers: staticModifiers, fields: fields)
            genericPassthroughFunc(
                modifiers: staticModifiers,
                name: "buildBlock",
                firstParameterName: .wildcardToken(),
                leadingTrivia: blankLineBeforeMember
            )
            genericPassthroughFunc(
                modifiers: staticModifiers,
                name: "buildEither",
                firstParameterName: .identifier("first"),
                leadingTrivia: blankLineBeforeMember
            )
            genericPassthroughFunc(
                modifiers: staticModifiers,
                name: "buildEither",
                firstParameterName: .identifier("second"),
                leadingTrivia: blankLineBeforeMember
            )
        }
    )
}

/// `Boxed<T>` for an already-parsed field type, spliced in directly with no
/// parsing involved.
private func boxedType(of fieldType: TypeSyntax) -> TypeSyntax {
    TypeSyntax(
        IdentifierTypeSyntax(
            name: .identifier("Boxed"),
            genericArgumentClause: GenericArgumentClauseSyntax(
                arguments: GenericArgumentListSyntax {
                    GenericArgumentSyntax(argument: .type(fieldType))
                }
            )
        )
    )
}

/// A single field's `boxedType` (Swift has no one-element tuple), or a
/// tuple of every field's `boxedType` for two or more fields. Used both as
/// `buildBlock`'s return type and as the `creation` closure's return type
/// (they must match).
private func combinedBoxedType(of fields: [MapperField]) -> TypeSyntax {
    guard fields.count > 1 else {
        return fields[0].boxedType
    }
    return TypeSyntax(
        TupleTypeSyntax(
            elements: TupleTypeElementListSyntax {
                for field in fields {
                    TupleTypeElementSyntax(type: field.boxedType)
                }
            }
        )
    )
}

/// The `creation` closure's own parameter list, e.g.
/// `_ Profile: Boxed<String>, _ Fullname: Boxed<String>` — the `_ Label:`
/// two-part form (no external label, `Label` as the internal name) is what
/// lets Xcode autocomplete the closure's parameter names from the field
/// labels, capitalized. Each element is placed on its own line (matching
/// the previous string template's layout): every element but the last gets
/// a trailing comma immediately followed by a newline, and the last gets a
/// bare trailing newline so the closure type's closing `)` starts its own
/// line.
private func creationClosureParameterList(for fields: [MapperField]) -> TupleTypeElementListSyntax {
    TupleTypeElementListSyntax(
        fields.enumerated().map { index, field in
            let isLast = index == fields.count - 1
            return TupleTypeElementSyntax(
                firstName: .wildcardToken(),
                secondName: .identifier(field.capitalizedLabel),
                colon: .colonToken(),
                type: boxedType(of: field.boxedType),
                trailingComma: isLast ? nil : .commaToken(),
                trailingTrivia: .newline
            )
        }
    )
}

/// `.init()`, used once per field as an argument to `creation(...)`.
private var dotInitCallExpr: FunctionCallExprSyntax {
    FunctionCallExprSyntax(
        calledExpression: MemberAccessExprSyntax(declName: DeclReferenceExprSyntax(baseName: .keyword(.`init`))),
        leftParen: .leftParenToken(),
        arguments: [],
        rightParen: .rightParenToken()
    )
}

/// `creation(.init(), .init(), ...)` — one `.init()` argument per field.
private func creationCallExpr(for fields: [MapperField]) -> FunctionCallExprSyntax {
    FunctionCallExprSyntax(
        calledExpression: DeclReferenceExprSyntax(baseName: .identifier("creation")),
        leftParen: .leftParenToken(),
        arguments: LabeledExprListSyntax {
            for _ in fields {
                LabeledExprSyntax(expression: dotInitCallExpr)
            }
        },
        rightParen: .rightParenToken()
    )
}

/// `let profile = creation(...)` for a single field, or
/// `let (profile, fullname) = creation(...)` for two or more, destructuring
/// the `creation` closure's result into one local per field.
private func creationBindingDecl(for fields: [MapperField]) -> VariableDeclSyntax {
    let pattern: PatternSyntax
    if fields.count == 1 {
        pattern = PatternSyntax(IdentifierPatternSyntax(identifier: .identifier(fields[0].label)))
    } else {
        pattern = PatternSyntax(
            TuplePatternSyntax(
                elements: TuplePatternElementListSyntax {
                    for field in fields {
                        TuplePatternElementSyntax(pattern: IdentifierPatternSyntax(identifier: .identifier(field.label)))
                    }
                }
            )
        )
    }

    return VariableDeclSyntax(
        bindingSpecifier: .keyword(.let),
        bindings: PatternBindingListSyntax {
            PatternBindingSyntax(
                pattern: pattern,
                initializer: InitializerClauseSyntax(value: creationCallExpr(for: fields))
            )
        }
    )
}

/// `self.init(profile: profile, fullname: fullname)` — the delegating call
/// that forwards every locally bound field to the canonical initializer.
private func delegatingSelfInitCallExpr(for fields: [MapperField]) -> FunctionCallExprSyntax {
    FunctionCallExprSyntax(
        calledExpression: MemberAccessExprSyntax(
            base: DeclReferenceExprSyntax(baseName: .keyword(.`self`)),
            declName: DeclReferenceExprSyntax(baseName: .keyword(.`init`))
        ),
        leftParen: .leftParenToken(),
        arguments: LabeledExprListSyntax {
            for field in fields {
                LabeledExprSyntax(
                    label: .identifier(field.label),
                    colon: .colonToken(),
                    expression: DeclReferenceExprSyntax(baseName: .identifier(field.label))
                )
            }
        },
        rightParen: .rightParenToken()
    )
}

/// The field-shaped `static func buildBlock(_ profile: String, _ fullname: String) -> (String, String) { (profile, fullname) }`
/// (or the single-field, non-tuple form) — the one `Builder` member whose
/// shape actually depends on the mapped type's fields.
private func fieldBuildBlockFunc(modifiers: DeclModifierListSyntax, fields: [MapperField]) -> FunctionDeclSyntax {
    let bodyExpr: ExprSyntax
    if fields.count == 1 {
        bodyExpr = ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(fields[0].label)))
    } else {
        bodyExpr = ExprSyntax(
            TupleExprSyntax(
                elements: LabeledExprListSyntax {
                    for field in fields {
                        LabeledExprSyntax(expression: DeclReferenceExprSyntax(baseName: .identifier(field.label)))
                    }
                }
            )
        )
    }

    return FunctionDeclSyntax(
        modifiers: modifiers,
        name: .identifier("buildBlock"),
        signature: FunctionSignatureSyntax(
            parameterClause: FunctionParameterClauseSyntax(
                parameters: FunctionParameterListSyntax {
                    for field in fields {
                        FunctionParameterSyntax(
                            firstName: .wildcardToken(),
                            secondName: .identifier(field.label),
                            type: field.parameterType
                        )
                    }
                }
            ),
            returnClause: ReturnClauseSyntax(type: combinedBoxedType(of: fields))
        ),
        body: CodeBlockSyntax { bodyExpr }
    )
}

/// One of the three fixed, field-count-independent `Builder` helpers:
/// `static func buildBlock<Component>(_ component: Component) -> Component`,
/// `static func buildEither<Component>(first component: Component) -> Component`,
/// or the `second` variant — all three simply pass their single argument
/// through unchanged.
private func genericPassthroughFunc(
    modifiers: DeclModifierListSyntax,
    name: String,
    firstParameterName: TokenSyntax,
    leadingTrivia: Trivia = []
) -> FunctionDeclSyntax {
    FunctionDeclSyntax(
        leadingTrivia: leadingTrivia,
        modifiers: modifiers,
        name: .identifier(name),
        genericParameterClause: GenericParameterClauseSyntax(
            parameters: GenericParameterListSyntax {
                GenericParameterSyntax(name: .identifier("Component"))
            }
        ),
        signature: FunctionSignatureSyntax(
            parameterClause: FunctionParameterClauseSyntax(
                parameters: FunctionParameterListSyntax {
                    FunctionParameterSyntax(
                        firstName: firstParameterName,
                        secondName: .identifier("component"),
                        type: IdentifierTypeSyntax(name: .identifier("Component"))
                    )
                }
            ),
            returnClause: ReturnClauseSyntax(type: IdentifierTypeSyntax(name: .identifier("Component")))
        ),
        body: CodeBlockSyntax {
            DeclReferenceExprSyntax(baseName: .identifier("component"))
        }
    )
}

/// Picks the initializer whose parameter list defines the generated
/// builder's fields.
///
/// - A struct/class with exactly one initializer always uses it —
///   `@MapperCanonical` is a no-op in that case, marked or not.
/// - With more than one initializer, `@Mapper` first checks for exactly one
///   initializer marked `@MapperCanonical` (always wins if present), then
///   falls back to auto-detecting the "memberwise-shaped" initializer: one
///   whose parameter labels are an exact set match against the type's own
///   stored property names. If neither resolves to exactly one candidate,
///   this is a compile-time error, since the field list would otherwise be
///   ambiguous.
private func resolveCanonicalInitializer(
    among initializers: [InitializerDeclSyntax],
    target: MapperTarget,
    context: some MacroExpansionContext
) -> InitializerDeclSyntax? {
    guard initializers.count > 1 else {
        return initializers.first
    }

    let markedInitializers = initializers.filter(\.isMarkedMapperCanonical)

    if markedInitializers.count > 1 {
        for markedInit in markedInitializers {
            context.diagnose(MapperDiagnostic.multipleCanonicalInitializers.diagnose(at: markedInit))
        }
        return nil
    }

    if let markedCanonicalInit = markedInitializers.first {
        return markedCanonicalInit
    }

    let storedPropertyNames = target.storedInstancePropertyNames
    let memberwiseShapedInitializers = initializers.filter { initializer in
        let labels = Set(
            initializer.signature.parameterClause.parameters.map { $0.firstName.text }
        )
        return labels == storedPropertyNames
    }

    if memberwiseShapedInitializers.count == 1 {
        return memberwiseShapedInitializers[0]
    }

    for initializer in initializers {
        context.diagnose(
            Diagnostic(
                node: Syntax(initializer),
                message: MapperDiagnostic.multipleInitializers,
                fixIts: [
                    FixIt(
                        message: MarkInitializerCanonicalFixIt(),
                        changes: [
                            .replace(
                                oldNode: Syntax(initializer),
                                newNode: Syntax(initializer.markedAsMapperCanonical)
                            ),
                        ]
                    ),
                ]
            )
        )
    }
    return nil
}

private extension MapperTarget {
    /// The names of this type's own stored, instance (non-static) properties
    /// — used only by the auto-detection heuristic in
    /// `resolveCanonicalInitializer`, never to define the generated
    /// builder's fields directly (that's still always the canonical
    /// initializer's parameter list, never property inspection).
    ///
    /// A property counts as "stored" here the same way the rest of this file
    /// already treats it: any `VariableDeclSyntax` binding, regardless of
    /// `let`/`var` or whether it has an initializer — computed properties
    /// (those with a `{ get ... }`/`{ get set }` accessor block instead of a
    /// plain initializer-or-nothing) are excluded, since they aren't part of
    /// what a memberwise initializer would set.
    var storedInstancePropertyNames: Set<String> {
        var names: Set<String> = []
        for member in memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) })
            else {
                continue
            }
            for binding in variable.bindings {
                guard bindingIsStored(binding) else { continue }
                if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                    names.insert(identifier.identifier.text)
                }
            }
        }
        return names
    }
}

/// A binding is a stored property (not computed) if it has no accessor
/// block, or its accessor block is a plain `{ willSet ... }`/`{ didSet ... }`
/// observer list rather than `{ get ... }`. This mirrors the same
/// distinction Swift itself makes between stored and computed properties.
private func bindingIsStored(_ binding: PatternBindingSyntax) -> Bool {
    guard let accessorBlock = binding.accessorBlock else {
        return true
    }
    switch accessorBlock.accessors {
    case let .accessors(accessorList):
        return accessorList.allSatisfy { accessor in
            accessor.accessorSpecifier.tokenKind == .keyword(.willSet)
                || accessor.accessorSpecifier.tokenKind == .keyword(.didSet)
        }
    case .getter:
        return false
    }
}

private extension InitializerDeclSyntax {
    /// Whether this initializer already carries a `@MapperCanonical`
    /// attribute. Matched by attribute name only (syntax-only, like every
    /// other check in this macro) — `@MapperCanonical` is itself just a
    /// no-op marker macro, so there's no semantic meaning to inspect.
    var isMarkedMapperCanonical: Bool {
        attributes.contains { element in
            guard case let .attribute(attribute) = element else {
                return false
            }
            // Match both the bare spelling (`@MapperCanonical`) and the
            // fully qualified one (`@SwiftMapper.MapperCanonical`), since a
            // consumer may need the qualified form to disambiguate against
            // another module's identically named attribute.
            if let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text {
                return name == "MapperCanonical"
            }
            if let memberName = attribute.attributeName.as(MemberTypeSyntax.self)?.name.text {
                return memberName == "MapperCanonical"
            }
            return false
        }
    }

    /// Returns a copy of this initializer with `@MapperCanonical` inserted
    /// as its first attribute, reusing this initializer's own leading trivia
    /// (blank lines/indentation) for the new attribute and leaving the
    /// initializer's original first token (`public`, `init`, ...) with just
    /// the trailing indentation, so the result reads naturally:
    ///
    /// ```swift
    /// @MapperCanonical
    /// init(value: String) {
    /// ```
    var markedAsMapperCanonical: InitializerDeclSyntax {
        let originalLeadingTrivia = leadingTrivia
        let indentation = originalLeadingTrivia.trailingIndentation
        let markerAttribute = AttributeListSyntax.Element.attribute(
            AttributeSyntax(
                leadingTrivia: originalLeadingTrivia,
                attributeName: IdentifierTypeSyntax(name: .identifier("MapperCanonical")),
                trailingTrivia: .newline
            )
        )
        return self
            .with(\.leadingTrivia, indentation)
            .with(\.attributes, AttributeListSyntax([markerAttribute] + Array(attributes)))
    }
}

private extension Trivia {
    /// The trailing run of spaces/tabs in this trivia — the indentation
    /// immediately before the token it's attached to, with any preceding
    /// newlines/blank lines dropped.
    var trailingIndentation: Trivia {
        guard let lastPiece = pieces.last else {
            return Trivia()
        }
        switch lastPiece {
        case .spaces, .tabs:
            return Trivia(pieces: [lastPiece])
        default:
            return Trivia()
        }
    }
}

/// The Fix-It offered alongside `MapperDiagnostic.multipleInitializers`:
/// mechanically inserting `@MapperCanonical` above the diagnosed initializer
/// is the standard fix once a struct needs more than one initializer.
private struct MarkInitializerCanonicalFixIt: FixItMessage {
    var message: String { "Mark this initializer @MapperCanonical" }

    var fixItID: MessageID {
        MessageID(domain: "SwiftMapper", id: "multipleInitializers.markCanonical")
    }
}

private struct MapperField {
    let label: String
    /// The type used as `Boxed<T>`'s generic argument, kept as the
    /// already-parsed `TypeSyntax` node the compiler produced for the
    /// user's own initializer parameter (only structurally rewritten, via
    /// `strippingParameterOnlyAnnotations`, never turned into a `String` and
    /// reparsed). Must not contain ownership specifiers or parameter-only
    /// attributes (`@escaping`, `@autoclosure`), since neither is valid in a
    /// generic-argument position (e.g. `Boxed<consuming String>` and
    /// `Boxed<@escaping () -> Void>` are both invalid Swift).
    let boxedType: TypeSyntax
    /// The type used for the generated `buildBlock`'s own parameter
    /// declaration, likewise kept as a `TypeSyntax` end-to-end. This *is* a
    /// real function parameter position, so it keeps `@escaping`/
    /// `@autoclosure` (needed to forward the value into the struct's
    /// escaping-requiring canonical initializer) while still dropping
    /// ownership specifiers, which the macro re-derives fresh rather than
    /// forwards.
    let parameterType: TypeSyntax

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
    /// Mirrors the type's own access level onto generated members. Only
    /// `public`/`open` need to be forwarded explicitly — `internal` (the
    /// default) requires no modifier. An `open` class (whose access level is
    /// visible outside the module, same as `public`) still only ever
    /// generates `public` members here, never `open`: the generated
    /// `convenience init` and nested `Builder` enum don't need to be
    /// overridable themselves for the builder DSL to be usable from another
    /// module.
    var isPublicOrOpen: Bool {
        contains { $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open) }
    }

    /// The modifier list to attach to each generated member: `[public]` if
    /// this type is `public`/`open`, otherwise empty.
    var mirroredForGeneratedMembers: DeclModifierListSyntax {
        isPublicOrOpen
            ? DeclModifierListSyntax { DeclModifierSyntax(name: .keyword(.public)) }
            : []
    }
}

private enum MapperDiagnostic: DiagnosticMessage {
    case notAStructOrClass
    case missingInitializer
    case multipleInitializers
    case multipleCanonicalInitializers
    case unsupportedParameter
    case unlabeledParameter
    case noFields
    case existingBuilderMemberCollision
    /// The canonical initializer has more fields than the keyword
    /// initializer's fixed set of statically-named `__MapperFieldBuilderN`
    /// typealiases can cover — see `keywordFieldBuilderMaxFieldCount`'s doc
    /// comment for why that set is a fixed, finite, explicitly-named list
    /// instead of `names: arbitrary`.
    case tooManyFieldsForKeywordInit(fieldCount: Int, maxFieldCount: Int)
    /// Two initializer parameters capitalize to the same generated builder
    /// closure parameter name (e.g. `value` and `Value`), which would
    /// otherwise silently produce an invalid, duplicate-named parameter in
    /// the generated builder initializer.
    case collidingCapitalizedFieldLabels(capitalizedLabel: String, otherParameterLabel: String)

    var message: String {
        switch self {
        case .notAStructOrClass:
            return "@Mapper can only be attached to a struct or class"
        case .missingInitializer:
            return "@Mapper requires the type to declare at least one initializer whose parameters define the mapped fields"
        case .multipleInitializers:
            return """
            @Mapper found more than one initializer; mark exactly one of them @MapperCanonical to tell \
            @Mapper which initializer's parameters define the mapped fields, or reduce the type to a \
            single initializer
            """
        case .multipleCanonicalInitializers:
            return "@Mapper found more than one initializer marked @MapperCanonical; only one is allowed per type"
        case .unsupportedParameter:
            return "@Mapper does not support variadic initializer parameters"
        case .unlabeledParameter:
            return "@Mapper requires every initializer parameter to have an explicit label; use the parameter's internal name as the label instead of '_'"
        case .noFields:
            return "@Mapper requires the initializer to declare at least one parameter"
        case let .collidingCapitalizedFieldLabels(capitalizedLabel, otherParameterLabel):
            return """
            @Mapper capitalizes this parameter's label to '\(capitalizedLabel)' for the generated builder \
            closure, but parameter '\(otherParameterLabel)' already capitalizes to the same name — the \
            generated builder initializer would end up with two parameters sharing that name. Rename one \
            of the two initializer parameters so their capitalized builder labels don't collide.
            """
        case .existingBuilderMemberCollision:
            return """
            @Mapper needs to generate a nested type named 'Builder' on this type, but it already \
            declares its own member named 'Builder'. Rename that member, or don't apply @Mapper to \
            this type.
            """
        case let .tooManyFieldsForKeywordInit(fieldCount, maxFieldCount):
            return """
            @Mapper's generated keyword initializer supports at most \(maxFieldCount) fields, but this \
            initializer declares \(fieldCount). Reduce the number of fields, or use the generated \
            Builder-DSL initializer instead, which has no such limit.
            """
        }
    }

    var diagnosticID: MessageID {
        let id: String
        switch self {
        case .notAStructOrClass: id = "notAStructOrClass"
        case .missingInitializer: id = "missingInitializer"
        case .multipleInitializers: id = "multipleInitializers"
        case .multipleCanonicalInitializers: id = "multipleCanonicalInitializers"
        case .unsupportedParameter: id = "unsupportedParameter"
        case .unlabeledParameter: id = "unlabeledParameter"
        case .noFields: id = "noFields"
        case .existingBuilderMemberCollision: id = "existingBuilderMemberCollision"
        case .collidingCapitalizedFieldLabels: id = "collidingCapitalizedFieldLabels"
        case .tooManyFieldsForKeywordInit: id = "tooManyFieldsForKeywordInit"
        }
        return MessageID(domain: "SwiftMapper", id: id)
    }

    var severity: DiagnosticSeverity {
        switch self {
        case .notAStructOrClass, .missingInitializer, .multipleInitializers, .multipleCanonicalInitializers,
             .unsupportedParameter, .unlabeledParameter, .noFields, .existingBuilderMemberCollision,
             .collidingCapitalizedFieldLabels, .tooManyFieldsForKeywordInit:
            return .error
        }
    }

    func diagnose(at node: some SyntaxProtocol) -> Diagnostic {
        Diagnostic(node: Syntax(node), message: self)
    }
}

/// Whether `target` already declares its own member (of any kind — type,
/// property, function, case) literally named `Builder`. Only possible since
/// the generated nested result-builder enum's name became fixed (`Builder`)
/// instead of derived from the attached type's own name — a type-specific
/// name could never collide with itself. Returns the first colliding
/// member's name token, for diagnosing at its exact location.
private func findExistingBuilderMemberCollision(in target: MapperTarget) -> TokenSyntax? {
    for member in target.memberBlock.members {
        if let nestedStruct = member.decl.as(StructDeclSyntax.self), nestedStruct.name.text == "Builder" {
            return nestedStruct.name
        }
        if let nestedClass = member.decl.as(ClassDeclSyntax.self), nestedClass.name.text == "Builder" {
            return nestedClass.name
        }
        if let nestedEnum = member.decl.as(EnumDeclSyntax.self), nestedEnum.name.text == "Builder" {
            return nestedEnum.name
        }
        if let typealiasDecl = member.decl.as(TypeAliasDeclSyntax.self), typealiasDecl.name.text == "Builder" {
            return typealiasDecl.name
        }
        if let variable = member.decl.as(VariableDeclSyntax.self) {
            for binding in variable.bindings {
                if let identifier = binding.pattern.as(IdentifierPatternSyntax.self), identifier.identifier.text == "Builder" {
                    return identifier.identifier
                }
            }
        }
        if let function = member.decl.as(FunctionDeclSyntax.self), function.name.text == "Builder" {
            return function.name
        }
    }
    return nil
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
