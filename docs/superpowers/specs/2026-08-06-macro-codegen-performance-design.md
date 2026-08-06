# Macro codegen performance + benchmarking doc

Status: approved (user requested implementation directly; scoping question on
benchmark deliverable and version answered autonomously while user was
unavailable — see "Decisions" below).

## Background

A performance analysis of SwiftMapper (this session, prior turn) found:

1. **Runtime cost is genuinely zero** — benchmarked and confirmed via
   disassembly (the generated builder call site fully inlines away in a
   release/WMO build). No runtime changes proposed.
2. **Macro-expansion compile time is the real lever.** `MapperMacro.swift`
   builds its two generated members (the builder `init` and the nested
   `Builder` enum) as large multi-line string literals fed through
   `DeclSyntax(stringLiteral:)`. This forces the compiler to re-parse that
   generated text on every single `@Mapper` expansion, unlike the rest of
   the file, which already builds typed `SwiftSyntaxBuilder` nodes for
   smaller pieces (attributes, trivia). This scales with the number of
   `@Mapper` usages in a consuming project.
3. No existing doc in the repo explains SwiftMapper's performance
   characteristics or gives contributors a way to reproduce/track them.

## Decisions

- **Version for this release: `2.11.0`** (minor). This repo's convention
  (see git tags) bumps patch only for docs-only changes with no code
  change (e.g. `2.10.1`); this change alters macro-generated output
  construction (even though the generated *text* is unchanged) and adds new
  tooling, so it gets a minor bump.
- **Benchmark deliverable: doc + runnable harness.** A written doc alone
  wouldn't let contributors reproduce or track numbers over time as the
  macro evolves. Add a small `Bench` executable target (gated so it doesn't
  affect normal consumers — it's dev-only, not part of the `SwiftMapper`
  product) plus `docs/BENCHMARKING.md` explaining what it measures, how to
  run it, and today's baseline numbers.

## Scope

### 1. Macro codegen rewrite (the performance fix)

Replace the two `DeclSyntax(stringLiteral: ...)` calls in
`MapperMacro.swift` with typed `SwiftSyntaxBuilder` construction:

- `builderInit` → build an `InitializerDeclSyntax` (or
  `DeclSyntax` from a `MemberBlockItemSyntax` built via
  `SyntaxNodeFactory`/normal initializers) instead of formatting a Swift
  source string and reparsing it.
- `builderEnum` → same, using `EnumDeclSyntax`/`FunctionDeclSyntax` nodes
  for the `@resultBuilder` enum and its four static methods.

**Non-goal:** changing the generated code's *behavior* or *shape*. The
existing `MapperMacroExpansionTests.swift` suite asserts exact expected
source text for a battery of inputs (generics, classes, multiple
initializers, single vs. multi-field, etc.) — those tests are the
regression safety net. If formatting differs from the current
string-template output in a way that breaks a test, prefer adjusting the
new builder's trivia to match the existing expected strings over changing
the tests, since the tests encode the current, already-shipped public
contract of what `@Mapper` generates. Whitespace-only formatting
differences that are clearly cosmetic (and don't change what compiles) are
fine to update in the expected-output test strings, called out explicitly
in the PR commit.

Also fix the incidental deprecation warning seen during builds
(`MemberMacro` should implement the `conformingTo:`-taking `expansion`
overload) while touching this file, since it's a trivial, directly related
cleanup in the same function being edited.

### 2. Benchmark harness

- New `Sources/Bench/main.swift` (executable target, name `Bench`),
  mirroring the microbenchmark already validated ad hoc this session:
  compares a `@Mapper` builder-constructed value, a hand-written
  initializer call, and a direct memberwise initializer call, over a large
  iteration count, and prints elapsed time for each.
- Added to `Package.swift` as a normal `.executableTarget` depending on
  `SwiftMapper` — consumers who only depend on the `SwiftMapper` library
  product are unaffected (SwiftPM only builds targets/products that are
  actually depended on).
- Not wired into CI (it's a manual, dev-run tool, not a correctness test —
  keeps CI time unchanged).

### 3. `docs/BENCHMARKING.md`

Explains:

- What's actually measured (runtime cost of the generated builder vs.
  hand-written code) and why compile-time cost — not runtime — is
  SwiftMapper's actual performance-relevant dimension for adopters.
- How to run the harness (`swift run -c release Bench`) and how to read
  its output.
- Today's baseline numbers from this session (with the important caveat:
  absolute numbers are hardware/toolchain-dependent — the point is the
  *relative* comparison staying ~1:1:1, not the absolute seconds).
- A short note on macro-expansion compile-time cost (qualitative, since
  it's project-size-dependent and not something a single number
  meaningfully summarizes) and a pointer to the codegen approach
  (typed syntax construction) as the mitigation.

### 4. Documentation updates

- `README.md`: add a short "Performance" section (runtime: zero-cost,
  measured; compile-time: standard macro/swift-syntax cost, see
  `docs/BENCHMARKING.md`) with a link to the new doc.
- No change needed to `CONTRIBUTING.md` requirements (Bench isn't a new
  public capability requiring a design-doc-first PR by its own rules —
  it's dev tooling — but the codegen rewrite touches the macro, so
  `CONTRIBUTING.md`'s existing testing requirements already cover it: run
  `swift build && swift test` before opening a PR).

### 5. Release

- Bump nothing in `Package.swift` (SwiftMapper doesn't hardcode its own
  version anywhere in-source — versioning is git-tag based per
  `README.md`'s install instructions and prior release history).
- Tag `2.11.0` (annotated tag, short message) and publish a GitHub release
  via `gh release create` with release notes describing the performance
  work, following the style of prior releases (e.g. `1.1.1`, `2.10.1`).

## Testing / verification

- `swift build && swift test` must pass unchanged (34 existing tests).
- Macro-expansion tests specifically must still pass with the same
  asserted generated-code strings (or intentionally, minimally updated
  ones if whitespace changes — documented in the commit).
- Run `Bench` in release mode after the rewrite to confirm the
  zero-cost runtime property still holds (it should — the rewrite only
  touches macro-expansion-time code generation, not the generated code's
  shape).
