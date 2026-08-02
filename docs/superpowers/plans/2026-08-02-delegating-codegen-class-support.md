# Delegating Codegen, Class Support, Auto-Detected Canonical Init Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch `@Mapper`'s generated initializer from whole-`self` reassignment to a delegating call, which simultaneously (a) adds `class` support, (b) removes the default-valued-`let`-property limitation, and (c) removes the Equatable/Hashable/Comparable compiler-bug limitation (by renaming the generated nested enum to a fixed `Builder` name); and make `@MapperCanonical` an override rather than a hard requirement by auto-detecting the memberwise-shaped initializer when unambiguous.

**Architecture:** All changes are confined to `Sources/SwiftMapperMacros/MapperMacro.swift` (core codegen + diagnostics), `Sources/SwiftMapper/Mapper.swift` (public macro declarations + doc comments), `README.md`, and the two test files under `Tests/SwiftMapperTests/`. No new files, no new public API surface beyond what's documented in the spec (class support, auto-detection, one new diagnostic).

**Tech Stack:** Swift 5.9+ macros (`SwiftSyntax`, `SwiftSyntaxMacros`, `SwiftDiagnostics`), `swift-testing` for integration tests, `XCTest` + `SwiftSyntaxMacrosTestSupport`'s `assertMacroExpansion` for expansion tests.

**Design spec:** `docs/superpowers/specs/2026-08-02-delegating-codegen-class-support-design.md` — read this first for full rationale; this plan implements it task-by-task.

**Build/test command (required in this sandbox):** `swift build --force-resolved-versions && swift test --force-resolved-versions` (plain `swift build`/`swift test` fail here with a `safe.bareRepository` error — always pass `--force-resolved-versions`).

**Commit convention note:** each task below ends with its own commit, for clean TDD checkpoints while implementing. This repo's established delivery convention for this PR, however, is **one single commit per delivered feature** (see the existing single commit `8b72af4` on this branch). Task 8, Step 1 squashes every commit made while executing this plan into one before pushing — do not push the per-task commits individually.

---

## Task 1: Rename `notAStruct` to describe struct-or-class, accept `ClassDeclSyntax`

**Files:**
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift:6-16` (the `guard let structDecl` at the top of `expansion`)
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift` (the `MapperDiagnostic` enum, `notAStruct` case)
- Test: `Tests/SwiftMapperTests/MapperMacroExpansionTests.swift:741` (`testDiagnosesNotAStruct`)

The current code only recognizes `StructDeclSyntax`. Both `StructDeclSyntax` and `ClassDeclSyntax` conform to `DeclGroupSyntax` and expose `.name` and `.memberBlock`, but they're different concrete types with no shared protocol that exposes both — so the rest of `expansion` needs a small abstraction to treat them uniformly. Introduce a local enum wrapping either case, extracting just the two things `expansion` actually needs: the type name and the member block. Everything else in `expansion` currently only reads `structDecl.name` and `structDecl.memberBlock` (confirmed by grep — no other structural difference between struct/class matters to this macro).

- [ ] **Step 1: Write the failing expansion test for a bare (non-struct-non-class) declaration**

Replace `testDiagnosesNotAStruct` (which currently uses a `class`, which will become valid) with a test using an `enum`, which stays invalid:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --force-resolved-versions --filter testDiagnosesNotAStructOrClass`
Expected: FAIL — the old message text ("@Mapper can only be attached to a struct") doesn't match, and the old test name no longer exists.

- [ ] **Step 3: Add a `MapperTarget` abstraction and update the diagnostic message**

In `MapperMacro.swift`, add this type near the top of the file (right after the imports, before `MapperMacro`):

```swift
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
}
```

Change the top of `expansion`:

```swift
        guard let target = MapperTarget(declaration) else {
            context.diagnose(MapperDiagnostic.notAStructOrClass.diagnose(at: declaration))
            return []
        }

        let typeName = target.name.text
```

and replace every other use of `structDecl` inside `expansion` (`structDecl.memberBlock`, passed to `warnAboutLikelyEquatableConformanceConflict`/`diagnoseDefaultValuedStoredProperties`, and `structDecl.modifiers.accessModifierPrefix`) with `target.memberBlock` / `target` / `target.modifiers.accessModifierPrefix` respectively — these two helper functions are removed entirely in Task 6, so don't worry about updating their signatures yet; for now just get `expansion` compiling against `target` instead of `structDecl`.

Rename the diagnostic case and update its message and ID:

```swift
    case notAStructOrClass
    // ...
        case .notAStructOrClass:
            return "@Mapper can only be attached to a struct or class"
    // ...
        case .notAStructOrClass: id = "notAStructOrClass"
```

(rename every other occurrence of `notAStruct` to `notAStructOrClass` throughout the file — there are three: the case declaration, the `message` switch, and the `diagnosticID` switch).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --force-resolved-versions --filter testDiagnosesNotAStructOrClass`
Expected: PASS. (The full suite will not build yet — `warnAboutLikelyEquatableConformanceConflict`/`diagnoseDefaultValuedStoredProperties` still take `StructDeclSyntax`, not `MapperTarget`; Task 6 removes them. For now, temporarily change their parameter type from `StructDeclSyntax` to accept whichever concrete type is available by switching on `target` at the call site — e.g. `if case let .structDecl(structDecl) = target { warnAboutLikelyEquatableConformanceConflict(in: structDecl, context: context) }` — so the file builds. This is throwaway scaffolding removed in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftMapperMacros/MapperMacro.swift Tests/SwiftMapperTests/MapperMacroExpansionTests.swift
git commit -m "Accept class declarations alongside structs in @Mapper's expansion entry point"
```

---

## Task 2: Auto-detect the memberwise-shaped canonical initializer

**Files:**
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift` (`resolveCanonicalInitializer`)
- Test: `Tests/SwiftMapperTests/MapperMacroExpansionTests.swift` (`testDiagnosesMultipleInitializers`, needs replacing — see below — plus new tests)

The current `resolveCanonicalInitializer` requires exactly one `@MapperCanonical`-marked initializer whenever there's more than one initializer, with no auto-detection. Add a step before falling back to "require the marker": if exactly one initializer's parameter labels are an exact set match against the target's own stored (non-static) property names, use it automatically.

- [ ] **Step 1: Write a failing expansion test for auto-detection (no marker needed)**

Add this test — a struct with a `Decodable`-style second initializer whose parameter labels don't resemble the stored properties at all, and *no* `@MapperCanonical` anywhere:

```swift
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
```

Note: this test's `expandedSource` already reflects the Task 3/4 delegating-codegen and fixed-`Builder`-name changes too, since those land before this test can pass end-to-end. That's fine — write it now, and don't expect it to pass until Task 4 is also done. Move on to Step 2 of *this* task first (the auto-detection logic itself, tested via a temporary assertion), then return to make this specific test fully green once Task 4 lands.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --force-resolved-versions --filter testAutoDetectsMemberwiseShapedInitializerWithoutMarker`
Expected: FAIL — today this diagnoses `multipleInitializers` since no initializer is marked `@MapperCanonical`.

- [ ] **Step 3: Add stored-property extraction and the auto-detection heuristic**

In `MapperMacro.swift`, add a helper to collect a target's own stored (non-computed, non-static) property names, and update `resolveCanonicalInitializer`:

```swift
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
```

Now update `resolveCanonicalInitializer` to take the target (for the property-name lookup) and add the auto-detection step:

```swift
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
```

(This replaces the whole function body — the `guard let canonicalInit = markedInitializers.first else { ... }` shape is gone, replaced by the `if let markedCanonicalInit = ...` early return plus the new memberwise-shaped check before the final ambiguous-diagnostic loop.)

Update the call site in `expansion`:

```swift
        guard let canonicalInit = resolveCanonicalInitializer(among: initializers, target: target, context: context) else {
            return []
        }
```

- [ ] **Step 4: Run test to verify the auto-detection logic itself is reachable**

Run: `swift build --force-resolved-versions`
Expected: builds cleanly (the full `testAutoDetectsMemberwiseShapedInitializerWithoutMarker` test still won't pass yet — its expected output uses the Task 3/4 delegating shape — but confirm no compiler errors from this task's changes by also running the existing, still-currently-passing marker test to confirm auto-detection doesn't break the marked case):

Run: `swift test --force-resolved-versions --filter testExpandsBuilderInitUsingMarkedCanonicalInitializer`
Expected: PASS (marked initializer still wins over auto-detection, since rule 2 — the explicit marker — is checked before rule 3).

- [ ] **Step 5: Update `testDiagnosesMultipleInitializers` — its scenario now auto-detects instead of erroring**

The existing test's `ThreeInits` struct (`init(value: String)`, `init()`, `init(other: Int)`, stored property `value: String`) now has exactly one memberwise-shaped initializer (`init(value: String)` — its label set `{value}` exactly matches the stored property set `{value}`), so it no longer diagnoses anything under the new rules. Replace the test with two: one proving auto-detection now handles that exact shape, and one exercising the *still*-ambiguous case (zero memberwise-shaped candidates).

Replace `testDiagnosesMultipleInitializers` with:

```swift
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
                    @Mapper which initializer's parameters define the mapped fields, or reduce the struct to a \
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
                    @Mapper which initializer's parameters define the mapped fields, or reduce the struct to a \
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
```

Note both new tests' `expandedSource` use the Task 3/4 delegating shape and fixed `Builder` name — same caveat as Step 1: this specific step's tests won't be fully green until Task 4 lands. That's expected; keep going.

- [ ] **Step 6: Add a test for the ambiguous *tie* case (2+ memberwise-shaped candidates)**

```swift
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
                    @Mapper which initializer's parameters define the mapped fields, or reduce the struct to a \
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
                    @Mapper which initializer's parameters define the mapped fields, or reduce the struct to a \
                    single initializer
                    """,
                    line: 10,
                    column: 5,
                    fixIts: [
                        FixItSpec(message: "Mark this initializer @MapperCanonical"),
                    ]
                ),
            ],
            macros: macros
        )
    }
```

This test (unlike the others in this task) has no delegating-codegen dependency in its expected output (it diagnoses before any codegen happens), so it can pass right now.

- [ ] **Step 7: Run it**

Run: `swift test --force-resolved-versions --filter testDiagnosesMultipleInitializersWhenAmbiguouslyMemberwiseShaped`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/SwiftMapperMacros/MapperMacro.swift Tests/SwiftMapperTests/MapperMacroExpansionTests.swift
git commit -m "Auto-detect the memberwise-shaped canonical initializer when unambiguous"
```

---

## Task 3: Switch codegen to delegating init + tuple-returning `buildBlock`, fixed `Builder` name

**Files:**
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift` (codegen in `expansion`, `builderInit`/`builderEnum`/`builderName`)
- Modify: `Sources/SwiftMapper/Mapper.swift` (the `@attached(member, names: arbitrary)` line)

This is the core change described in the spec. Replace the whole-`self`-reassignment codegen with a delegating call, change `buildBlock` to aggregate raw values instead of constructing the type, and rename the generated nested enum from `<Type>Builder` to a fixed `Builder`.

- [ ] **Step 1: Update `Mapper.swift`'s attached-macro name declaration**

```swift
@attached(member, names: named(init), named(Builder))
public macro Mapper() = #externalMacro(module: "SwiftMapperMacros", type: "MapperMacro")
```

(This alone will make every currently-passing expansion test that references `<Type>Builder` fail to compile as real Swift once used outside `assertMacroExpansion`'s syntax-only checking — but `assertMacroExpansion` doesn't type-check, so existing expansion tests still run; only the integration tests, which do compile, will be affected once this task's codegen change lands. Doing this rename now, before the codegen change, keeps the two changes in the same commit but doesn't break anything yet since expansion tests are string-based.)

- [ ] **Step 2: Replace the builder-name, builder-init, and builder-enum codegen in `expansion`**

Replace this block in `MapperMacro.swift`:

```swift
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
```

with:

```swift
        let accessModifier = target.modifiers.accessModifierPrefix
        let builderName = "Builder"

        let builderClosureParameters = fields
            .map { "        _ \($0.capitalizedLabel): Boxed<\($0.boxedType)>" }
            .joined(separator: ",\n")

        let creationArguments = fields.map { _ in ".init()" }.joined(separator: ", ")

        // A single field's buildBlock returns the bare value (Swift has no
        // one-element tuple), so the delegating call binds it to a plain
        // `let`; two or more fields' buildBlock returns a tuple, destructured
        // via a tuple `let` pattern.
        let creationBinding: String
        let delegatingArguments: String
        if fields.count == 1 {
            let onlyField = fields[0]
            creationBinding = "let \(onlyField.label) = creation(\(creationArguments))"
            delegatingArguments = "\(onlyField.label): \(onlyField.label)"
        } else {
            let bindingNames = fields.map(\.label).joined(separator: ", ")
            creationBinding = "let (\(bindingNames)) = creation(\(creationArguments))"
            delegatingArguments = fields
                .map { "\($0.label): \($0.label)" }
                .joined(separator: ", ")
        }

        let buildBlockReturnType = fields.count == 1
            ? fields[0].parameterType
            : "(\(fields.map(\.parameterType).joined(separator: ", ")))"

        let initKeyword = target.isClass ? "convenience init" : "init"

        let builderInit = """
        \(accessModifier)\(initKeyword)(
            @\(builderName)
            _ creation: (
        \(builderClosureParameters)
            ) -> \(buildBlockReturnType)
        ) {
            \(creationBinding)
            self.init(\(delegatingArguments))
        }
        """

        let buildBlockParameters = fields
            .map { "_ \($0.label): \($0.parameterType)" }
            .joined(separator: ", ")
        let buildBlockBody = fields.count == 1
            ? fields[0].label
            : "(\(fields.map(\.label).joined(separator: ", ")))"

        let builderEnum = """
        @resultBuilder
        \(accessModifier)enum \(builderName) {
            \(accessModifier)static func buildBlock(\(buildBlockParameters)) -> \(buildBlockReturnType) {
                \(buildBlockBody)
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
```

`typeName` is no longer referenced in this block (it was only used for `\(typeName)Builder` and `\(typeName)(...)`) — leave the `let typeName = target.name.text` declaration in place, since it's still used elsewhere (diagnostics reference the type only indirectly; double check with `grep -n typeName Sources/SwiftMapperMacros/MapperMacro.swift` after this change — if it's now unused, remove the `let typeName = ...` line and the compiler will confirm via an "unused variable" warning if you missed a use).

- [ ] **Step 3: Run the full test suite and fix expected-output drift**

Run: `swift build --force-resolved-versions && swift test --force-resolved-versions 2>&1 | tail -100`

Expected: every expansion test that asserts a `self = creation(...)` / `<Type>Builder` shape now fails, showing a diff between expected and actual. This is expected — proceed to Task 4 to update every affected expansion test in one pass (rather than fixing them one at a time here), since the same mechanical transformation applies to all of them.

- [ ] **Step 4: Commit** (once Task 4's test updates make the suite green — see Task 4's own commit step; this task's code change and Task 4's test updates land as one commit together, since the code change alone leaves the suite red)

---

## Task 4: Update every existing expansion test to the new generated shape

**Files:**
- Modify: `Tests/SwiftMapperTests/MapperMacroExpansionTests.swift`

Apply the same mechanical transformation to every remaining test whose `expandedSource` still shows the old `self = creation(...)` / `<Type>Builder` shape. The transformation, in general terms:
- `_ creation: (...) -> Self` → `_ creation: (...) -> (Field1Type, Field2Type, ...)` (or the bare single field type for one field)
- `@\(TypeName)Builder` → `@Builder` (the attribute reference on the closure parameter)
- `self = creation(args)` → `let (field1, field2, ...) = creation(args)` then `self.init(field1: field1, field2: field2, ...)` (or `let field1 = creation(args)` / `self.init(field1: field1)` for a single field)
- `enum \(TypeName)Builder {` → `enum Builder {`
- `static func buildBlock(_ field1: T1, _ field2: T2) -> \(TypeName) { \(TypeName)(field1: field1, field2: field2) }` → `static func buildBlock(_ field1: T1, _ field2: T2) -> (T1, T2) { (field1, field2) }` (or the single-field bare-value form)

Apply this to each of the following tests in `MapperMacroExpansionTests.swift`, replacing their `expandedSource` string exactly as shown:

- [ ] **Step 1: `testExpandsBuilderInitAndResultBuilder`**

Replace its `expandedSource` (currently ending in the old `ProfileHeaderDataBuilder` shape) with:

```swift
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
```

- [ ] **Step 2: `testStripsOwnershipSpecifiersFromParameterTypes`**

Replace its `expandedSource` with:

```swift
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
```

- [ ] **Step 3: `testKeepsGlobalActorAttributeButStripsEscapingFromParameterTypes`**

Replace its `expandedSource` with:

```swift
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
```

Note: this is a single-field struct, so `buildBlockReturnType` is the field's `parameterType` (`@MainActor @escaping () -> Int`, i.e. the type *with* `@escaping` — re-check against Task 3's code: `buildBlockReturnType` for the single-field case uses `fields[0].parameterType`, which **keeps** `@escaping`. But a function's *return type* cannot itself carry `@escaping` (that's only valid in parameter position) — this is a real bug the tests must catch. Verify this by actually running the build in Step 6 below; if the compiler rejects `@escaping` in the return-type position, change the single-field `buildBlockReturnType` computation in Task 3 to use a *new*, stripped-of-`@escaping` type string instead of reusing `parameterType` verbatim (reuse the existing `strippingParameterOnlyAnnotations` stripping, which is already computed as `boxedType` — for the return-type position specifically, `boxedType` is the correct string to reuse, since it's already had `@escaping`/`@autoclosure` stripped for exactly this reason: it's used as a generic argument today, and a function return type has the same restriction). Go back and fix Task 3's `buildBlockReturnType` to use `fields[0].boxedType` instead of `fields[0].parameterType` for the single-field case (the multi-field tuple case is unaffected, since the tuple's *elements* are still fine as `parameterType` — a tuple isn't a parameter or return-type position itself, its elements are ordinary type positions... but re-verify: are ownership specifiers valid inside a tuple element? Test this directly — write a throwaway `.swift` file with `func f() -> (consuming String, Int)` and compile it with `swiftc` to check before deciding; if invalid, use `boxedType` for every field in `buildBlockReturnType`, not just the single-field case, and adjust the corresponding `buildBlockBody` line to match, since the return type and the actual returned expression must agree).

- [ ] **Step 4: Resolve the ownership-specifier/`@escaping` return-type question empirically before continuing**

Run this exact probe:

```bash
cat > /tmp/return_type_probe.swift << 'SWIFTEOF'
func single() -> @escaping () -> Int { { 1 } }
func tupleWithConsuming() -> (consuming String, Int) { ("a", 1) }
SWIFTEOF
swiftc -typecheck /tmp/return_type_probe.swift
rm /tmp/return_type_probe.swift
```

Expected: both lines fail to compile (`@escaping` is only valid on a parameter; `consuming`/`borrowing` are only valid on a parameter, not inside a tuple type). Given that, `buildBlockReturnType` must always use each field's `boxedType` (already stripped of both ownership specifiers and parameter-only attributes), never `parameterType`, in **both** the single-field and multi-field cases. Go back to Task 3 and change:

```swift
        let buildBlockReturnType = fields.count == 1
            ? fields[0].parameterType
            : "(\(fields.map(\.parameterType).joined(separator: ", ")))"
```

to:

```swift
        let buildBlockReturnType = fields.count == 1
            ? fields[0].boxedType
            : "(\(fields.map(\.boxedType).joined(separator: ", ")))"
```

`buildBlockBody`'s expression (`\(field.label)` / `(field1, field2, ...)`) doesn't change — only the declared return *type* string changes; `buildBlock`'s *parameters* still correctly use `parameterType` (a real parameter position, where `@escaping`/ownership specifiers are required to accept the canonical initializer's own escaping-closure/ownership parameters). Re-derive Step 3's expected `expandedSource` for `testKeepsGlobalActorAttributeButStripsEscapingFromParameterTypes` with this corrected understanding — the return type there is `@MainActor () -> Int` (i.e. `boxedType`, matching what's already shown above in Step 3; that expected block was already written using `boxedType`'s value, so no further change is needed there — this step exists to confirm and lock in *why* `boxedType` is correct everywhere, and to catch the single-field-only bug before it ships).

- [ ] **Step 5: `testDiagnosesMissingInitializer` — unaffected**

No change needed (this test never reaches codegen).

- [ ] **Step 6: Run the full suite to check progress so far**

Run: `swift build --force-resolved-versions && swift test --force-resolved-versions --filter MapperMacroExpansionTests 2>&1 | tail -150`
Expected: remaining failures only in tests not yet updated (listed in the following steps) — confirm the tests updated so far now pass, and read any actual-vs-expected diff carefully for whitespace drift (the `assertMacroExpansion` diff output shows exact expected/actual side by side); adjust indentation in this plan's blocks above to match if the real macro output differs in whitespace only (e.g. blank-line placement) — the logic described is correct, but exact trivia is easiest to confirm by running the real macro, not by hand-authoring.

- [ ] **Step 7: `testDiagnosesMultipleCanonicalInitializers` — unaffected**

No change needed (this test never reaches codegen — it errors out before generating anything).

- [ ] **Step 8: `testExpandsBuilderInitUsingMarkedCanonicalInitializer`**

Replace its `expandedSource` (the trailing `UserBuilder` codegen block) with:

```swift
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
```

(keep everything before that block in the `expandedSource` — the struct body and both hand-written initializers — unchanged).

- [ ] **Step 9: `testRecognizesFullyQualifiedMapperCanonicalAttribute`**

Apply the identical replacement as Step 8 (same `User`/`id`/`name` shape) to this test's trailing codegen block.

- [ ] **Step 10: `testDiagnosesUnlabeledParameterWithFixIt` — unaffected**

No change needed (errors before codegen).

- [ ] **Step 11: `testExpandsBuilderInitForGenericStructWithWhereClause`**

Replace its `expandedSource` trailing block with:

```swift
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
```

- [ ] **Step 12: `testDiagnosesCollidingCapitalizedFieldLabels` — unaffected**

No change needed (errors before codegen).

- [ ] **Step 13: Delete `testWarnsAboutLikelyEquatableConformanceConflict` and `testDiagnosesDefaultValuedStoredProperty`**

Both scenarios no longer diagnose anything once Task 6 removes their detection functions — delete these two test methods entirely now (rather than updating their expected output), since Task 6 will remove the diagnostics they assert. Deleting them here (slightly ahead of Task 6's production-code removal) is fine — they'll simply keep passing today's behavior until Task 6 lands, at which point there's nothing left asserting the old warning/error, so no red window occurs.

- [ ] **Step 14: Run the full expansion test file**

Run: `swift test --force-resolved-versions --filter MapperMacroExpansionTests 2>&1 | tail -150`
Expected: PASS for every test except any that depend on Task 6 (removed diagnostics — already deleted in Step 13, so none should remain) or Task 5 (new `Builder`-collision diagnostic — not yet added, so nothing references it yet). All should be green at this point.

- [ ] **Step 15: Commit**

```bash
git add Sources/SwiftMapperMacros/MapperMacro.swift Sources/SwiftMapper/Mapper.swift Tests/SwiftMapperTests/MapperMacroExpansionTests.swift
git commit -m "Switch generated init to delegating codegen with a fixed Builder enum name"
```

---

## Task 5: Add class support to `expansion`, plus new class expansion + integration tests

**Files:**
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift` (already accepts `ClassDeclSyntax` via `MapperTarget` from Task 1; this task adds the tests proving it end-to-end, and verifies `target.isClass` correctly drives `convenience init`)
- Test: `Tests/SwiftMapperTests/MapperMacroExpansionTests.swift` (new test)
- Test: `Tests/SwiftMapperTests/MapperIntegrationTests.swift` (new test type + new `@Test`)

- [ ] **Step 1: Write a failing expansion test for a class**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --force-resolved-versions --filter testExpandsConvenienceInitForClass`
Expected: FAIL — as of Task 4, `target.isClass` should already correctly select `convenience init`, so this specific test may in fact already pass if Tasks 1–4 were done correctly. If it fails, the diff will show whether the issue is the `init`/`convenience init` keyword or something else — fix `MapperTarget.isClass`'s usage in the `initKeyword` computation in Task 3's code if needed.

- [ ] **Step 3: Confirm/fix, then run again**

Run: `swift test --force-resolved-versions --filter testExpandsConvenienceInitForClass`
Expected: PASS.

- [ ] **Step 4: Add a real, compiling integration test for a class (not just expansion-string matching)**

Add to `MapperIntegrationTests.swift`, alongside the other file-scope `@Mapper`-attached types:

```swift
@Mapper
private final class PersonBox: Equatable {
    let firstName: String
    let lastName: String

    init(firstName: String, lastName: String) {
        self.firstName = firstName
        self.lastName = lastName
    }

    static func == (lhs: PersonBox, rhs: PersonBox) -> Bool {
        lhs.firstName == rhs.firstName && lhs.lastName == rhs.lastName
    }
}
```

Add a test to the `MapperIntegrationTests` suite:

```swift
    @Test("Classes support the generated convenience builder initializer")
    func classBuilderSupport() {
        let built = PersonBox { FirstName, LastName in
            FirstName { "Ada" }
            LastName { "Lovelace" }
        }

        #expect(built == PersonBox(firstName: "Ada", lastName: "Lovelace"))
    }
```

- [ ] **Step 5: Run it**

Run: `swift test --force-resolved-versions --filter classBuilderSupport`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SwiftMapperMacros/MapperMacro.swift Tests/SwiftMapperTests/MapperMacroExpansionTests.swift Tests/SwiftMapperTests/MapperIntegrationTests.swift
git commit -m "Add class-support expansion and integration tests"
```

---

## Task 6: Remove the two obsolete diagnostics, add the `Builder`-name-collision diagnostic

**Files:**
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift`

- [ ] **Step 1: Write a failing expansion test for the new `Builder`-name-collision diagnostic**

```swift
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
                    line: 4,
                    column: 5
                ),
            ],
            macros: macros
        )
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --force-resolved-versions --filter testDiagnosesExistingBuilderMemberCollision`
Expected: FAIL (compiles today with no diagnostic, generating a second, colliding `Builder` member).

- [ ] **Step 3: Add the detection + diagnostic**

Add a helper near the other target-inspecting helpers in `MapperMacro.swift`:

```swift
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
```

Add the new diagnostic case to `MapperDiagnostic`:

```swift
    case existingBuilderMemberCollision
```

```swift
        case .existingBuilderMemberCollision:
            return """
            @Mapper needs to generate a nested type named 'Builder' on this type, but it already \
            declares its own member named 'Builder'. Rename that member, or don't apply @Mapper to \
            this type.
            """
```

```swift
        case .existingBuilderMemberCollision: id = "existingBuilderMemberCollision"
```

Add it to the `severity` switch's error case list (`.error`).

Call it early in `expansion`, right after resolving `target`:

```swift
        if let collidingMember = findExistingBuilderMemberCollision(in: target) {
            context.diagnose(MapperDiagnostic.existingBuilderMemberCollision.diagnose(at: collidingMember))
            return []
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --force-resolved-versions --filter testDiagnosesExistingBuilderMemberCollision`
Expected: PASS.

- [ ] **Step 5: Remove `defaultValuedStoredProperty` and its detection**

Delete:
- The `MapperDiagnostic.defaultValuedStoredProperty` case (from the enum declaration, `message`, `diagnosticID`, and `severity` switches).
- The `diagnoseDefaultValuedStoredProperties(in:context:)` function entirely.
- Its call site in `expansion`:

```swift
        guard !diagnoseDefaultValuedStoredProperties(in: structDecl, context: context) else {
            return []
        }
```

(This call site should already have been converted to something like `if case let .structDecl(structDecl) = target { ... }` as throwaway scaffolding in Task 1, Step 3 — remove that scaffolding entirely now, for both this function and the next.)

- [ ] **Step 6: Remove `likelyEquatableConformanceConflict` and its detection**

Delete:
- The `MapperDiagnostic.likelyEquatableConformanceConflict` case (from all four switches).
- The `warnAboutLikelyEquatableConformanceConflict(in:context:)` function entirely.
- Its call site in `expansion`.

- [ ] **Step 7: Run the full suite**

Run: `swift build --force-resolved-versions && swift test --force-resolved-versions 2>&1 | tail -150`
Expected: builds cleanly; all remaining tests pass (no test should still reference either removed diagnostic — confirmed by Task 4 Step 13 already deleting their expansion tests).

- [ ] **Step 8: Add a passing-compilation integration test proving each removed limitation is actually gone**

Add to `MapperIntegrationTests.swift`:

```swift
@Mapper
private struct WithDefaultValuedID: Identifiable, Equatable, Sendable {
    let id: Int = 42
    let value: String

    init(value: String) {
        self.value = value
    }
}

@Mapper
private struct HandWrittenEquatableWitness: Equatable {
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
```

Add tests:

```swift
    @Test("A stored let property with an in-place default value now compiles and works with @Mapper")
    func defaultValuedStoredPropertyNoLongerBreaksTheBuild() {
        let built = WithDefaultValuedID { Value in
            Value { "hello" }
        }

        #expect(built.id == 42)
        #expect(built.value == "hello")
    }

    @Test("A hand-written Equatable witness alongside @Mapper no longer triggers swiftlang/swift#70087")
    func handWrittenEquatableWitnessNoLongerConflicts() {
        let built = HandWrittenEquatableWitness { Id, Render in
            Id { 1 }
            Render { { 42 } }
        }

        #expect(built == HandWrittenEquatableWitness(id: 1, render: { 42 }))
    }
```

- [ ] **Step 9: Run these two new tests**

Run: `swift test --force-resolved-versions --filter defaultValuedStoredPropertyNoLongerBreaksTheBuild`
Run: `swift test --force-resolved-versions --filter handWrittenEquatableWitnessNoLongerConflicts`
Expected: both PASS. (If either fails to *compile*, that means one of the two root-cause fixes from the design spec isn't actually wired up correctly — re-check Task 3's delegating codegen and Task 4's fixed `Builder` name before concluding the design assumption itself was wrong; both were empirically pre-validated in the design spec's investigation, so a failure here most likely indicates an implementation slip, not a flawed premise.)

- [ ] **Step 10: Also update/replace the now-inaccurate comment on `MainActorClosureFieldData`**

That struct's comment currently explains it *avoids* declaring a hand-written `Equatable` witness "because that would trigger a known Swift compiler bug." Since Step 8 above already added a dedicated test proving that's fixed, simplify the comment on `MainActorClosureFieldData` to just describe what it tests (global-actor-isolated escaping closure field support), removing the now-obsolete workaround explanation:

```swift
@Mapper
private struct MainActorClosureFieldData {
    let id: Int
    let render: @MainActor () -> Int

    init(id: Int, render: @MainActor @escaping () -> Int) {
        self.id = id
        self.render = render
    }
}
```

(i.e. delete the `// Note: this struct intentionally does *not* conform to ...` comment block above it entirely.)

- [ ] **Step 11: Run the full suite one more time**

Run: `swift build --force-resolved-versions && swift test --force-resolved-versions`
Expected: all tests pass.

- [ ] **Step 12: Commit**

```bash
git add Sources/SwiftMapperMacros/MapperMacro.swift Tests/SwiftMapperTests/MapperMacroExpansionTests.swift Tests/SwiftMapperTests/MapperIntegrationTests.swift
git commit -m "Remove default-valued-property and Equatable-conflict diagnostics; add Builder-name-collision diagnostic"
```

---

## Task 7: Update `Mapper.swift` doc comments and `README.md`

**Files:**
- Modify: `Sources/SwiftMapper/Mapper.swift`
- Modify: `README.md`

- [ ] **Step 1: Update `Mapper.swift`'s doc comment for `@Mapper`**

Update the doc comment's example expansion (the `ProfileHeaderDataBuilder` block) to match the new delegating/tuple/fixed-`Builder`-name shape (same transformation as Task 4), and update the "Requirements (v1)" bullet list:

```swift
/// Generates a composable, type-safe "field builder" initializer for a
/// struct or class.
///
/// Attach `@Mapper` to a struct or class that declares one canonical
/// initializer — the one that sets every stored property. The macro reads
/// that initializer's parameter list and adds:
///
/// - A nested `@resultBuilder` enum (always named `Builder`) whose
///   `buildBlock` mirrors the canonical initializer's parameters in order.
/// - A second, additive initializer (`convenience init` for a class, a
///   plain `init` for a struct) that takes a `@Builder` closure with one
///   labeled `Boxed<T>` parameter per field, so callers can write the
///   field's mapping logic as a small, labeled DSL instead of a single flat
///   initializer call. This generated initializer *delegates* to the
///   canonical initializer — it never constructs the type directly — so it
///   works identically whether the canonical initializer is a struct's
///   memberwise-style `init` or a class's designated `init`.
///
/// Given:
///
/// ```swift
/// @Mapper
/// public struct ProfileHeaderData: Identifiable, Equatable, Sendable {
///     public let id: UUID
///     public let profile: TdsAvatar.Configuration
///     public let fullname: DataState<String>
///     public let nickname: String
///
///     public init(
///         profile: TdsAvatar.Configuration,
///         fullname: DataState<String>,
///         nickname: String
///     ) {
///         self.id = .init()
///         self.profile = profile
///         self.fullname = fullname
///         self.nickname = nickname
///     }
/// }
/// ```
///
/// the macro adds the equivalent of:
///
/// ```swift
/// extension ProfileHeaderData {
///     public init(
///         @Builder
///         _ creation: (
///             _ Profile: Boxed<TdsAvatar.Configuration>,
///             _ Fullname: Boxed<DataState<String>>,
///             _ Nickname: Boxed<String>
///         ) -> (TdsAvatar.Configuration, DataState<String>, String)
///     ) {
///         let (profile, fullname, nickname) = creation(.init(), .init(), .init())
///         self.init(profile: profile, fullname: fullname, nickname: nickname)
///     }
///
///     @resultBuilder
///     public enum Builder {
///         public static func buildBlock(
///             _ profile: TdsAvatar.Configuration,
///             _ fullname: DataState<String>,
///             _ nickname: String
///         ) -> (TdsAvatar.Configuration, DataState<String>, String) {
///             (profile, fullname, nickname)
///         }
///
///         public static func buildBlock<Component>(_ component: Component) -> Component {
///             component
///         }
///
///         public static func buildEither<Component>(first component: Component) -> Component {
///             component
///         }
///
///         public static func buildEither<Component>(second component: Component) -> Component {
///             component
///         }
///     }
/// }
/// ```
///
/// letting call sites write:
///
/// ```swift
/// ProfileHeaderData { Profile, Fullname, Nickname in
///     Profile { .init(url: domain.avatarURL) }
///     Fullname { .loaded(domain.fullName) }
///     Nickname { domain.playerName }
/// }
/// ```
///
/// `if`/`else` and `switch` can appear directly inside that closure — each
/// branch just needs to produce the same field type. See the generated
/// `buildEither` functions above.
///
/// ## Requirements (v1)
///
/// - `@Mapper` must be attached to a `struct` or `class`.
/// - The type must declare **exactly one** explicit initializer, *or*, if
///   it declares more than one, either exactly one of them must be marked
///   `@MapperCanonical`, or exactly one of them must be "memberwise-shaped"
///   (its parameter labels are an exact set match against the type's own
///   stored property names) — `@Mapper` auto-detects that case, no marker
///   needed. See `MapperCanonical` for when the marker is still required.
///   That initializer defines the fields, order, types, and labels used by
///   the generated builder — the macro does not otherwise inspect stored
///   properties, so any property not part of that initializer's parameter
///   list (an `id` given a fresh default value, for example) is left alone.
/// - Initializer parameters must be simple `label: Type` parameters — no
///   variadics, and no parameter packs. Default values on the canonical
///   initializer are ignored by the generated builder (every field must be
///   supplied there).
/// - Generic structs are supported, including `where` clauses and
///   constraints on the generic parameters — because `@Mapper` is a
///   *member* macro, the builder initializer and its nested `Builder` enum
///   are generated lexically inside the type's own body, so they see its
///   generic parameters the same way any other member would.
/// - The type must not already declare its own member named `Builder`
///   (the name the generated nested result-builder enum always uses).
@attached(member, names: named(init), named(Builder))
public macro Mapper() = #externalMacro(module: "SwiftMapperMacros", type: "MapperMacro")
```

- [ ] **Step 2: Update `MapperCanonical`'s doc comment**

Change the framing from "required whenever there's more than one initializer" to "override for when auto-detection can't or shouldn't apply":

```swift
/// Marks the initializer that `@Mapper` should treat as canonical when the
/// attached type declares more than one initializer and auto-detection
/// isn't enough to tell which one.
///
/// When a type declares more than one initializer, `@Mapper` first tries to
/// auto-detect which one is canonical: if exactly one initializer's
/// parameter labels are an exact set match (same names, any order) against
/// the type's own stored property names, that one is used automatically —
/// no marker needed. This handles the common case, e.g. a `Decodable`
/// type's hand-written `init(from:)` doesn't remotely resemble a memberwise
/// initializer, so there's no ambiguity to resolve:
///
/// ```swift
/// @Mapper
/// struct User: Decodable {
///     let id: UUID
///     let name: String
///
///     // Auto-detected: its labels (id, name) exactly match this type's
///     // stored properties, and init(from:) clearly isn't a candidate.
///     init(id: UUID, name: String) {
///         self.id = id
///         self.name = name
///     }
///
///     init(from decoder: Decoder) throws {
///         let container = try decoder.container(keyedBy: CodingKeys.self)
///         self.id = try container.decode(UUID.self, forKey: .id)
///         self.name = try container.decode(String.self, forKey: .name)
///     }
/// }
/// ```
///
/// `@MapperCanonical` is still needed when auto-detection can't resolve the
/// ambiguity itself — for example, two initializers whose labels both
/// happen to exactly match the stored properties (just reordered), or a
/// type whose canonical initializer intentionally excludes a self-managed
/// property (like `ProfileHeaderData.id` above) *and* also declares more
/// than one initializer. Attach `@MapperCanonical` to the initializer that
/// should define the generated builder's fields in that case, and
/// `@Mapper` uses it — always taking priority over auto-detection — while
/// leaving every other initializer untouched:
///
/// ```swift
/// @Mapper
/// struct User: Decodable {
///     let id: UUID
///     let name: String
///
///     @MapperCanonical
///     init(id: UUID, name: String) {
///         self.id = id
///         self.name = name
///     }
///
///     init(from decoder: Decoder) throws {
///         let container = try decoder.container(keyedBy: CodingKeys.self)
///         self.id = try container.decode(UUID.self, forKey: .id)
///         self.name = try container.decode(String.self, forKey: .name)
///     }
/// }
/// ```
///
/// `@MapperCanonical` is a marker only — it generates no code of its own.
/// `@Mapper` reports a compile-time error if a multi-initializer type has
/// more than one initializer marked `@MapperCanonical`, or if none is
/// marked and auto-detection also can't find exactly one unambiguous
/// candidate.
@attached(peer, names: arbitrary)
public macro MapperCanonical() = #externalMacro(module: "SwiftMapperMacros", type: "MapperCanonicalMacro")
```

- [ ] **Step 3: Update `README.md`'s "Requirements (v1)" section**

Replace the bullet list at `README.md`'s "Requirements (v1)" section (currently starting `- @Mapper must be attached to a struct.`) with:

```markdown
- `@Mapper` must be attached to a `struct` or `class`.
- The type must declare **exactly one** explicit initializer, *or*, if it
  declares more than one, either exactly one of them must be marked
  `@MapperCanonical`, or exactly one of them must be "memberwise-shaped" —
  its parameter labels are an exact set match against the type's own stored
  property names — which `@Mapper` auto-detects with no marker needed (see
  [Multiple initializers](#multiple-initializers) below). That
  initializer's parameter list — labels, types, and order — defines the
  generated builder. Properties not part of that initializer (for example
  an `id` given a fresh default value inside the initializer body) are left
  untouched.
- For a class, the generated additive initializer is always a `convenience
  init` delegating to the class's own designated (canonical) initializer —
  `@Mapper` never generates a designated initializer, so it never needs to
  know about a superclass's `super.init(...)` call.
- Initializer parameters must be simple `label: Type` parameters: no
  variadics, no unlabeled (`_`) parameters, no parameter packs. Ownership
  specifiers (`consuming`, `borrowing`) on a parameter are supported and
  don't affect the generated builder's field type. Parameter-only attributes
  (`@escaping`, `@autoclosure`) are also stripped from the field's `Boxed<T>`
  type, while type-level attributes that are part of the type itself (e.g.
  `@MainActor`, `@Sendable` on a function-typed field) are preserved.
- Generic structs are supported, including `where` clauses and constraints
  on the generic parameters. `@Mapper` is a *member* macro, so the generated
  builder initializer and its nested `Builder` enum sit lexically inside the
  type's own body and see its generic parameters the same way any other
  member would — no extra syntax is needed:

  ```swift
  @Mapper
  struct LabeledValue<Value: Equatable>: Equatable {
      let label: String
      let value: Value

      init(label: String, value: Value) {
          self.label = label
          self.value = value
      }
  }

  let count = LabeledValue<Int> { Label, Value in
      Label { "count" }
      Value { items.count }
  }
  ```
- The type must not already declare its own member named `Builder` — that's
  the name the generated nested result-builder enum always uses.

These constraints are intentionally narrow for v1 — see
[Non-goals](#non-goals) for why.
```

- [ ] **Step 4: Update the "How it works" section's generated-code example**

Replace the `extension Address { ... }` code block in "How it works" with:

```markdown
```swift
extension Address {
    init(
        @Builder
        _ creation: (
            _ Street: Boxed<String>,
            _ City: Boxed<String>,
            _ PostalCode: Boxed<String>
        ) -> (String, String, String)
    ) {
        let (street, city, postalCode) = creation(.init(), .init(), .init())
        self.init(street: street, city: city, postalCode: postalCode)
    }

    @resultBuilder
    enum Builder {
        static func buildBlock(_ street: String, _ city: String, _ postalCode: String) -> (String, String, String) {
            (street, city, postalCode)
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
```
```

- [ ] **Step 5: Update the "Multiple initializers" section**

Replace its lead paragraph and example to describe auto-detection as the primary path:

```markdown
## Multiple initializers

`@Mapper` needs exactly one initializer to define the generated builder's
fields, but real-world types sometimes need more than one — a hand-written
`Decodable.init(from:)`, or a convenience initializer that call sites
needing the builder never use. When that happens, `@Mapper` first tries to
auto-detect which initializer is canonical: if exactly one initializer's
parameter labels are an exact set match against the type's own stored
property names, that one is used automatically, no marker required:

```swift
@Mapper
struct User: Decodable {
    let id: UUID
    let name: String

    // Auto-detected: its labels exactly match this type's stored
    // properties, and init(from:) clearly isn't a candidate.
    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
    }
}

let user = User { Id, Name in
    Id { UUID() }
    Name { rawInput.name }
}
```

If auto-detection can't find exactly one unambiguous candidate — for
example, two initializers whose labels both happen to match the stored
properties (just reordered) — attach `@MapperCanonical` to the initializer
that should define the generated builder's fields. It always takes priority
over auto-detection, and every other initializer is left completely
untouched:

```swift
@Mapper
struct User: Decodable {
    let id: UUID
    let name: String

    @MapperCanonical
    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
    }
}
```

`@MapperCanonical` is a marker only — it never generates any code of its
own. It has no effect (and isn't required) when a type declares only a
single initializer. Marking more than one initializer `@MapperCanonical` on
the same type is a compile-time error, and so is the rare case where
auto-detection also can't find exactly one unambiguous candidate — see
[Diagnostics](#diagnostics) below.
```

- [ ] **Step 6: Replace the "Diagnostics" list's default-value/Equatable-conflict bullets, add the `Builder`-collision bullet**

In the "Diagnostics" section, replace:

```markdown
- **Not a struct** — `@Mapper` can only be attached to a struct.
```

with:

```markdown
- **Not a struct or class** — `@Mapper` can only be attached to a struct or
  class.
```

Replace:

```markdown
- **Multiple initializers** — emitted at every initializer when a struct
  declares more than one and none of them is marked `@MapperCanonical`,
  with a **Fix-It** that inserts `@MapperCanonical` above that initializer.
  See [Multiple initializers](#multiple-initializers) above.
```

with:

```markdown
- **Multiple initializers** — emitted at every initializer when a type
  declares more than one, none of them is marked `@MapperCanonical`, and
  auto-detection can't find exactly one unambiguous memberwise-shaped
  candidate, with a **Fix-It** that inserts `@MapperCanonical` above each
  initializer. See [Multiple initializers](#multiple-initializers) above.
```

Delete these two bullets entirely:

```markdown
- **Default-valued `let` property** (error) — emitted when a stored `let`
  property declares an in-place default value (e.g. `let id: UUID = .init()`).
  This always breaks the build once `@Mapper`'s generated builder init is
  added — see [Known limitations](#known-limitations) for why, and how to fix
  it.
- **Likely `Equatable`/`Hashable`/`Comparable` conflict** (warning, not an
  error) — emitted when the struct conforms to one of those protocols *and*
  already hand-writes `==`/`<`/`hash(into:)` itself. This shape can trigger a
  known Swift compiler bug when combined with `@Mapper` — see
  [Known limitations](#known-limitations).
```

Add, in their place:

```markdown
- **Existing `Builder` member collision** — emitted when the type already
  declares its own member named `Builder`, which is the fixed name the
  generated nested result-builder enum always uses. Rename that member, or
  don't apply `@Mapper` to this type.
```

- [ ] **Step 7: Delete the "Known limitations" section entirely**

Both limitations it documents (default-valued `let` properties, the
Equatable/Hashable/Comparable compiler bug) are fixed — remove the whole
`## Known limitations` section (both subsections) from `README.md`, along
with any remaining cross-references to it (search for `Known limitations`
after the edits above and confirm zero remaining references — the two
already replaced in Steps 3 and 6 should be the only ones).

- [ ] **Step 8: Verify no remaining stale references**

Run: `grep -n "arbitrary\|<Type>Builder\|Known limitations\|self = creation" README.md Sources/SwiftMapper/Mapper.swift`
Expected: no output (or only incidental matches unrelated to this change — inspect any hits manually).

- [ ] **Step 9: Commit**

```bash
git add README.md Sources/SwiftMapper/Mapper.swift
git commit -m "Update docs for class support, auto-detected canonical init, and removed limitations"
```

---

## Task 8: Squash, full verification, push, update PR

**Files:** none (verification only)

- [ ] **Step 1: Squash every commit made while executing this plan into one**

Find the last commit that predates this plan's work (the review-fix commit
already on the branch):

```bash
git log --oneline -5
```

Interactively rebase from that commit forward, squashing all of this
plan's task commits into one, e.g.:

```bash
git reset --soft 8b72af4
git commit -m "Add class support, auto-detected @MapperCanonical, and delegating codegen

- Generated init now delegates to the canonical initializer (self.init(...)
  / convenience init(...)) instead of reassigning self, which is required
  for classes and also eliminates the default-valued-let-property
  compiler-limitation.
- The generated nested result-builder enum is now always named Builder
  (was <Type>Builder), letting @Mapper declare its exact generated member
  set instead of names: arbitrary, which eliminates the
  Equatable/Hashable/Comparable compiler bug (swiftlang/swift#70087).
- @Mapper now accepts class in addition to struct.
- @MapperCanonical is now auto-detected (the memberwise-shaped initializer)
  when unambiguous; the marker remains as an override for genuine ties.
- Removed the defaultValuedStoredProperty and
  likelyEquatableConformanceConflict diagnostics (no longer needed); added
  a new diagnostic for a type that already declares its own Builder member.

See docs/superpowers/specs/2026-08-02-delegating-codegen-class-support-design.md
for full rationale."
```

Verify the branch still shows exactly the expected commits on top of
`main` (the original review-fix commit, the spec commit, and this new
squashed commit):

```bash
git log --oneline main..HEAD
```

- [ ] **Step 2: Run the complete build and test suite**

Run: `swift build --force-resolved-versions && swift test --force-resolved-versions`
Expected: PASS, zero failures, zero warnings introduced by this change (check for "unused variable" warnings from the `typeName` question flagged in Task 3 Step 2).

- [ ] **Step 3: Grep for any remaining references to removed identifiers**

Run: `grep -rn "notAStruct\b\|defaultValuedStoredProperty\|likelyEquatableConformanceConflict\|diagnoseDefaultValuedStoredProperties\|warnAboutLikelyEquatableConformanceConflict" Sources/ Tests/ README.md`
Expected: no output.

- [ ] **Step 4: Review the diff for anything unintended**

Run: `git log --oneline main..feature/greatest-swiftmapper` and `git diff 8b72af4..HEAD --stat`
Expected: only the files listed in this plan's tasks appear; no unrelated changes.

- [ ] **Step 5: Push and update the PR**

```bash
git push origin feature/greatest-swiftmapper
```

Post a PR comment (via `gh pr comment 1`) summarizing this change: delegating codegen, class support, auto-detected `@MapperCanonical`, and the two removed known limitations — pointing at the design spec for full rationale.

- [ ] **Step 6: Consider a follow-up code-review round**

Per the `requesting-code-review` skill (already used once on this PR), dispatch another review round on the new commits before considering this workstream done, given the size and risk of this change (core codegen rewrite).
