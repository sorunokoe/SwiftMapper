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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "509.0.0"),
    ],
    targets: [
        // The compiler plugin that implements the `@Mapper` macro.
        .macro(
            name: "SwiftMapperMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
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
