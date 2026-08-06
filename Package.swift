// swift-tools-version: 5.9
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwiftMapper",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13),
    ],
    products: [
        .library(name: "SwiftMapper", targets: ["SwiftMapper"]),
    ],
    dependencies: [
        // An explicit upper bound (rather than `from:`) keeps this package
        // resolvable alongside other swift-syntax consumers that pin newer
        // 6xx releases — swift-syntax's leading version component tracks
        // Swift compiler releases, so `from:` alone (an "up to next major"
        // range) would only match the 509.x line.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"700.0.0"),
    ],
    targets: [
        // The compiler plugin that implements the `@Mapper` macro.
        .macro(
            name: "SwiftMapperMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                // Only used for its result-builder-based node initializers
                // (e.g. `FunctionParameterListSyntax { ... }`), which build
                // real, already-typed `SwiftSyntax` list nodes directly —
                // never string-literal-based `Syntax`-parsing APIs. See
                // `MapperMacro.swift`'s codegen for why this distinction
                // matters.
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),

        // The client library. Consumers only ever import this target;
        // it re-exports the macro declaration and ships `Boxed<T>`.
        .target(
            name: "SwiftMapper",
            dependencies: ["SwiftMapperMacros"]
        ),

        .testTarget(
            name: "SwiftMapperTests",
            dependencies: [
                "SwiftMapper",
                "SwiftMapperMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
