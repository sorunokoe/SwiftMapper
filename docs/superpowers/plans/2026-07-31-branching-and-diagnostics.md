# SwiftMapper Branching + Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `if`/`else`, `switch`, and optional `if` appear directly inside a `@Mapper`-generated builder closure (removing the README's documented branching workaround), and fix/improve the macro's compiler diagnostics.

**Architecture:** Extend the single code-generation site in `MapperMacro.swift` (the `builderEnum` string template) to also emit three generic, identity-passthrough `buildEither`/`buildOptional` functions. Fix `multipleInitializers` to diagnose each extra initializer at its own node instead of at the kept one. Add a mechanical Fix-It to `unlabeledParameter`. Update docs and tests to match.

**Tech Stack:** Swift 5.9 macros (`SwiftSyntax`, `SwiftSyntaxMacros`, `SwiftDiagnostics`), `swift-testing` + `XCTest` (`SwiftSyntaxMacrosTestSupport`) for tests.

**Design doc:** `docs/superpowers/specs/2026-07-31-branching-and-diagnostics-design.md`

---

### Task 1: Generate `buildEither`/`buildOptional` in the builder enum

**Files:**
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift:82-89` (the `builderEnum` template)
- Modify: `Tests/SwiftMapperTests/MapperMacroExpansionTests.swift:10-58` (`testExpandsBuilderInitAndResultBuilder`)

- [ ] **Step 1: Update the failing expectation first**

Edit `testExpandsBuilderInitAndResultBuilder`'s `expandedSource` in
`Tests/SwiftMapperTests/MapperMacroExpansionTests.swift` — replace the
`ProfileHeaderDataBuilder` enum body:

```swift
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
```

(Indentation must match whatever the existing `buildBlock` block already
uses in that file — copy the surrounding brace/indent style exactly, don't
reformat the rest of the test.)

- [ ] **Step 2: Run the test and confirm it now fails on the new expectation**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift test --filter MapperMacroExpansionTests/testExpandsBuilderInitAndResultBuilder 2>&1 | tail -60
```
Expected: FAIL — actual expansion is missing `buildEither`/`buildOptional`.
The failure output prints both "actual" and "expected" source; keep that
output handy for Step 4 in case indentation doesn't match exactly.

- [ ] **Step 3: Implement the macro change**

In `Sources/SwiftMapperMacros/MapperMacro.swift`, replace the `builderEnum`
template (currently lines 82-89):

```swift
        let builderEnum = """
        @resultBuilder
        \(accessModifier)enum \(builderName) {
            \(accessModifier)static func buildBlock(\(buildBlockParameters)) -> \(typeName) {
                \(typeName)(\(buildBlockArguments))
            }
        }
        """
```

with:

```swift
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
```

- [ ] **Step 4: Run the test again and reconcile whitespace if needed**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift test --filter MapperMacroExpansionTests/testExpandsBuilderInitAndResultBuilder 2>&1 | tail -60
```
Expected: PASS. If it still fails purely on whitespace/indentation (the
macro-expansion pretty-printer auto-indents generated members to match the
struct's own nesting level, which can differ slightly from a hand-typed
guess), copy the "actual" block from the failure diff verbatim into
`expandedSource` in the test and rerun until PASS. Do not change the
`diagnostics:` or macro logic to force a match — only adjust whitespace in
the expected string.

- [ ] **Step 5: Update the macro's doc comment example**

In `Sources/SwiftMapper/Mapper.swift`, the doc comment (around lines 52-61)
shows the generated `ProfileHeaderDataBuilder`. Add the three new functions
to that example so the docs stay accurate:

```swift
///     @resultBuilder
///     public enum ProfileHeaderDataBuilder {
///         public static func buildBlock(
///             _ profile: TdsAvatar.Configuration,
///             _ fullname: DataState<String>,
///             _ nickname: String
///         ) -> ProfileHeaderData {
///             ProfileHeaderData(profile: profile, fullname: fullname, nickname: nickname)
///         }
///
///         public static func buildEither<Component>(first component: Component) -> Component {
///             component
///         }
///
///         public static func buildEither<Component>(second component: Component) -> Component {
///             component
///         }
///
///         public static func buildOptional<Component>(_ component: Component?) -> Component? {
///             component
///         }
///     }
```

- [ ] **Step 6: Commit**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
git add Sources/SwiftMapperMacros/MapperMacro.swift Sources/SwiftMapper/Mapper.swift Tests/SwiftMapperTests/MapperMacroExpansionTests.swift
git commit -m "Generate buildEither/buildOptional to support branching in builder closures"
```

---

### Task 2: Fix `multipleInitializers` to diagnose each extra initializer

**Files:**
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift:27-31`
- Modify: `Tests/SwiftMapperTests/MapperMacroExpansionTests.swift:84-122` (`testDiagnosesMultipleInitializers`)

- [ ] **Step 1: Update the test first — expect one diagnostic per extra initializer**

Replace `testDiagnosesMultipleInitializers` in
`Tests/SwiftMapperTests/MapperMacroExpansionTests.swift` with a version that
has **three** initializers (so the fix is unambiguous — "point at the 2nd
one" alone wouldn't distinguish "diagnose the last" from "diagnose all
extras") and expects two diagnostics, at the 2nd and 3rd initializers:

```swift
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
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift test --filter MapperMacroExpansionTests/testDiagnosesMultipleInitializers 2>&1 | tail -40
```
Expected: FAIL — today's implementation emits exactly one diagnostic, at
line 5 (the first initializer), not two diagnostics at lines 9 and 13.

- [ ] **Step 3: Implement the fix**

In `Sources/SwiftMapperMacros/MapperMacro.swift`, replace:

```swift
        guard initializers.count == 1 else {
            context.diagnose(MapperDiagnostic.multipleInitializers.diagnose(at: canonicalInit))
            return []
        }
```

with:

```swift
        guard initializers.count == 1 else {
            for extraInit in initializers.dropFirst() {
                context.diagnose(MapperDiagnostic.multipleInitializers.diagnose(at: extraInit))
            }
            return []
        }
```

- [ ] **Step 4: Run the test again**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift test --filter MapperMacroExpansionTests/testDiagnosesMultipleInitializers 2>&1 | tail -40
```
Expected: PASS. If the line/column numbers don't match, read the actual
values from the failure output and correct the `DiagnosticSpec` line/column
values in the test (the source text above is authoritative — recount lines
1-indexed from `@Mapper` if adjusting).

- [ ] **Step 5: Commit**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
git add Sources/SwiftMapperMacros/MapperMacro.swift Tests/SwiftMapperTests/MapperMacroExpansionTests.swift
git commit -m "Diagnose each extra initializer individually instead of the kept one"
```

---

### Task 3: Add a Fix-It + clearer message to `unlabeledParameter`

**Files:**
- Modify: `Sources/SwiftMapperMacros/MapperMacro.swift:40-44` (the check inside the parameter loop) and the `MapperDiagnostic` enum (`unlabeledParameter` case, `message`, and a new `FixItMessage` type)
- Modify: `Tests/SwiftMapperTests/MapperMacroExpansionTests.swift` (add a new test)

- [ ] **Step 1: Write the new failing test first**

Add this test to `MapperMacroExpansionTests.swift` (anywhere after the
existing tests, before the closing `}` of the class):

```swift
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
                    line: 4,
                    column: 10,
                    fixIts: [
                        FixItSpec(message: "Use 'value' as the parameter's label"),
                    ]
                ),
            ],
            macros: macros
        )
    }
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift test --filter MapperMacroExpansionTests/testDiagnosesUnlabeledParameterWithFixIt 2>&1 | tail -60
```
Expected: FAIL — current message text differs ("(no '_' parameters)" instead
of "use the parameter's internal name..."), and no Fix-It is produced today.
Note the actual `line`/`column` SwiftSyntax reports for the `_` token in the
failure output — adjust the test's `line`/`column` to match if they differ
from the guess above.

- [ ] **Step 3: Implement the Fix-It message type and updated diagnostic**

In `Sources/SwiftMapperMacros/MapperMacro.swift`, add a new private type
right after the `MapperDiagnostic` enum (after its closing `}`):

```swift
private struct UnlabeledParameterFixIt: FixItMessage {
    let newLabel: String

    var message: String { "Use '\(newLabel)' as the parameter's label" }

    var fixItID: MessageID {
        MessageID(domain: "SwiftMapper", id: "unlabeledParameter.useInternalName")
    }
}
```

Update the `unlabeledParameter` case's message in the `MapperDiagnostic`
enum's `message` computed property:

```swift
        case .unlabeledParameter:
            return "@Mapper requires every initializer parameter to have an explicit label; use the parameter's internal name as the label instead of '_'"
```

Then update the parameter-loop check (currently):

```swift
            let label = parameter.firstName.text
            guard label != "_" else {
                context.diagnose(MapperDiagnostic.unlabeledParameter.diagnose(at: parameter))
                return []
            }
```

to attach a Fix-It when the parameter has an internal (second) name to
promote to the label:

```swift
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
```

This needs `import SwiftDiagnostics` (already present) and `SwiftSyntax`'s
`with(_:_:)` node-mutation helper (already available since `SwiftSyntax` is
imported). Note this diverges slightly from `MapperDiagnostic.diagnose(at:)`
(which only takes a node, no `fixIts:`) — use the `Diagnostic(node:message:fixIts:)`
initializer directly here instead of the `.diagnose(at:)` helper, since that
helper doesn't accept Fix-Its.

- [ ] **Step 4: Run the test again**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift test --filter MapperMacroExpansionTests/testDiagnosesUnlabeledParameterWithFixIt 2>&1 | tail -60
```
Expected: PASS. Adjust `line`/`column` in the test to match actual output if
they differ (SwiftSyntax positions are byte-offset-derived and can be
off-by-one from a hand guess — trust the compiler's own output).

- [ ] **Step 5: Run the full test suite to make sure nothing else broke**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift test 2>&1 | tail -80
```
Expected: all tests pass, including the untouched `testDiagnosesNotAStruct`
and `testDiagnosesMissingInitializer` (their messages are unchanged by this
task).

- [ ] **Step 6: Commit**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
git add Sources/SwiftMapperMacros/MapperMacro.swift Tests/SwiftMapperTests/MapperMacroExpansionTests.swift
git commit -m "Add Fix-It and clearer message for unlabeled initializer parameters"
```

---

### Task 4: Integration tests for real branching usage

**Files:**
- Modify: `Tests/SwiftMapperTests/MapperIntegrationTests.swift`

- [ ] **Step 1: Add an if/else branching test**

Append to `MapperIntegrationTests.swift` (inside the `MapperIntegrationTests`
struct, after the existing two `@Test` functions):

```swift
    @Test("if/else can appear directly inside the builder closure")
    func ifElseBranchingInsideBuilderClosure() {
        func build(isSenior: Bool) -> PersonData {
            PersonData { FirstName, LastName, Age in
                FirstName { "Ada" }
                LastName { "Lovelace" }
                if isSenior {
                    Age { 90 }
                } else {
                    Age { 36 }
                }
            }
        }

        #expect(build(isSenior: true) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 90))
        #expect(build(isSenior: false) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 36))
    }

    @Test("switch can appear directly inside the builder closure")
    func switchBranchingInsideBuilderClosure() {
        enum Era {
            case victorian, modern, contemporary
        }

        func build(era: Era) -> PersonData {
            PersonData { FirstName, LastName, Age in
                FirstName { "Ada" }
                LastName { "Lovelace" }
                switch era {
                case .victorian:
                    Age { 36 }
                case .modern:
                    Age { 70 }
                case .contemporary:
                    Age { 100 }
                }
            }
        }

        #expect(build(era: .victorian) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 36))
        #expect(build(era: .modern) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 70))
        #expect(build(era: .contemporary) == PersonData(firstName: "Ada", lastName: "Lovelace", age: 100))
    }
```

- [ ] **Step 2: Add an Optional-field plain-`if` test with its own mapper struct**

Add a new private struct and test, in the same file (top-level, alongside
`PersonData`):

```swift
@Mapper
private struct NicknameData: Equatable, Sendable {
    let firstName: String
    let nickname: String?

    init(firstName: String, nickname: String?) {
        self.firstName = firstName
        self.nickname = nickname
    }
}
```

and, inside the `MapperIntegrationTests` struct:

```swift
    @Test("plain if (no else) can appear directly inside the builder closure for an Optional field")
    func plainIfBranchingForOptionalField() {
        func build(hasNickname: Bool) -> NicknameData {
            NicknameData { FirstName, Nickname in
                FirstName { "Grace" }
                if hasNickname {
                    Nickname { "Amazing Grace" }
                }
            }
        }

        #expect(build(hasNickname: true) == NicknameData(firstName: "Grace", nickname: "Amazing Grace"))
        #expect(build(hasNickname: false) == NicknameData(firstName: "Grace", nickname: nil))
    }
```

- [ ] **Step 3: Run the new tests**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift test --filter MapperIntegrationTests 2>&1 | tail -60
```
Expected: all tests in `MapperIntegrationTests` PASS, including the three
new ones. If `plainIfBranchingForOptionalField` fails to compile with a type
mismatch, that indicates Task 1's `buildOptional` wasn't wired correctly —
go back and check the generated `NicknameDataBuilder` enum (add a temporary
`-Xfrontend -dump-macro-expansions` build if needed to inspect it, then
remove the flag afterward).

- [ ] **Step 4: Run the full suite**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
swift build && swift test 2>&1 | tail -80
```
Expected: build succeeds, all tests (existing + new, across both test
files) pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
git add Tests/SwiftMapperTests/MapperIntegrationTests.swift
git commit -m "Add integration tests for if/else, switch, and optional-if branching"
```

---

### Task 5: Update the README

**Files:**
- Modify: `README.md:175-194` (the "A note on branching" section)

- [ ] **Step 1: Replace the branching section**

Replace the entire "## A note on branching" section (lines 175-194) with:

````markdown
## Branching inside the builder closure

`if`/`else` and `switch` work directly inside a `@Mapper`-generated builder
closure — each branch just needs to produce the same field type:

```swift
Handicap { Trend in
    switch domain.trend {
    case .up:
        Trend { .up }
    case .down:
        Trend { .down }
    case .none:
        Trend { .flat }
    }
}
```

A plain `if` (no `else`) works too, for fields whose declared type is
already `Optional`:

```swift
@Mapper
struct Player: Equatable {
    let name: String
    let nickname: String?

    init(name: String, nickname: String?) {
        self.name = name
        self.nickname = nickname
    }
}

Player { Name, Nickname in
    Name { domain.fullName }
    if let preferred = domain.preferredNickname {
        Nickname { preferred }
    }
}
```

If a non-optional field's `if` is missing an `else`, the compiler rejects
it — the same way `let x: String = condition ? "a" : nil` would be rejected
anywhere else in Swift. That's expected: a non-optional field can't be left
unset.
````

- [ ] **Step 2: Verify the README's code samples still match reality**

There's no automated doc-test for the README, so verify by hand: re-read
the new section once more and confirm every example either (a) matches an
example already proven by a test in Task 4, or (b) is simple enough to be
obviously correct (the `Player`/`nickname` example mirrors
`NicknameData` from Task 4 exactly in shape).

- [ ] **Step 3: Commit**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
git add README.md
git commit -m "Update README: branching now works directly in builder closures"
```

---

### Task 6: Full verification, version bump, and release

**Files:** none (verification + tagging only)

- [ ] **Step 1: Full clean build + test**

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
rm -rf .build/arm64-apple-macosx .build/debug* .build/build.db .build/index-build .build/plugin-tools.yaml 2>/dev/null
swift build --skip-update
swift test --skip-update 2>&1 | tail -100
```
Expected: build succeeds with 0 errors; all tests (original + new from
Tasks 1-4) pass.

- [ ] **Step 2: Tag and release 1.1.0**

This is a backward-compatible, additive change (new generated members, no
removed/changed public API) — a minor version bump per semver.

```bash
cd /Users/yesa/Documents/Projects/Trackman/SwiftMapper
git tag -a 1.1.0 -m "1.1.0: branching support (if/else, switch, optional if) inside builder closures; improved diagnostics"
git push origin main
git push origin 1.1.0
gh release create 1.1.0 --title "1.1.0" --notes "- Builder closures now support if/else and switch directly (via generated buildEither/buildOptional).
- Plain if (no else) now works for Optional-typed fields.
- multipleInitializers diagnostic now points at each extra initializer instead of the kept one.
- unlabeledParameter diagnostic now includes a Fix-It suggesting the parameter's internal name as its label, and has clearer wording."
```

- [ ] **Step 3: Bump the GolfApp (nord) consumer to pick up the new release**

```bash
cd /Users/yesa/Documents/Projects/Trackman/nord/iosApp/Packages
swift package update swiftmapper --skip-update=false 2>&1 | tail -30
git diff Package.resolved | head -30
```
Expected: `Package.resolved`'s `swiftmapper` pin now shows `1.1.0`
(this file is gitignored in the `nord` repo, so this step is local-only —
no commit needed there). If the sandbox's bare-repository restriction blocks
this (as it did for the initial `1.0.0` pin), manually edit the `revision`
and `version` fields for the `swiftmapper` entry in
`iosApp/Packages/Package.resolved` to the new tag's commit SHA (obtain via
`git rev-parse 1.1.0^{commit}` in the `SwiftMapper` repo) and `1.1.0`, then
rebuild with `swift build --skip-update` from `iosApp/Packages` to confirm
it still resolves and builds.

- [ ] **Step 4: Confirm GolfApp still builds and its Profile tests still pass**

```bash
cd /Users/yesa/Documents/Projects/Trackman/nord/iosApp/Packages
swift build --target TrackmanProfile --skip-update 2>&1 | tail -40
swift test --filter ProfileTests --skip-update 2>&1 | tail -60
```
Expected: 0 build errors; 99/99 `ProfileTests` still pass (this change is
additive-only, so no behavior change is expected in GolfApp's existing
mappers — this step just confirms the version bump didn't regress
anything).
