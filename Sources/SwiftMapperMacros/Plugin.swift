import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiftMapperPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        MapperMacro.self,
        MapperCanonicalMacro.self,
    ]
}
