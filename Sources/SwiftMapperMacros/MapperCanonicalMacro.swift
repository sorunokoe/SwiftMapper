import SwiftSyntax
import SwiftSyntaxMacros

/// Implements the `@MapperCanonical` marker attribute. See `Mapper.swift`
/// in the `SwiftMapper` target for the full user-facing documentation.
///
/// `@MapperCanonical` never generates any code of its own — it only needs
/// to exist as a real macro so the attribute is valid Swift syntax.
/// `MapperMacro` looks for its presence directly on a struct's or class's
/// initializer declarations (via `AttributeListSyntax`) to decide which
/// initializer is canonical when the type declares more than one and
/// auto-detection can't resolve the ambiguity on its own.
public struct MapperCanonicalMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
