# Benchmarking

SwiftMapper has two, very different performance dimensions: the **runtime**
cost of a value built through `@Mapper`'s generated builder, and the
**compile-time** cost of expanding `@Mapper` itself. This doc covers both —
what's measured, how to reproduce it, and what to expect as your project
grows.

## Runtime cost: zero, by construction

`@Mapper`'s generated builder initializer never allocates, dispatches
dynamically, or does anything beyond gathering values and delegating to
your own canonical initializer:

```swift
public init(@Builder _ creation: (...) -> (...)) {
    let (profile, fullname) = creation(.init(), .init())
    self.init(profile: profile, fullname: fullname)
}
```

In a release (whole-module-optimization) build, this fully inlines away:
the `Builder` closure, the `Boxed<T>` wrappers, and the delegating call all
disappear, leaving only the work your own field closures actually do. There
is no per-field runtime overhead versus writing the initializer call by
hand.

### Reproducing this

The `Bench` executable target (`Sources/Bench/main.swift`) constructs the
same value three ways — through the `@Mapper` builder, through the type's
own hand-written initializer, and through a plain memberwise initializer
with no `@Mapper` involved at all — over 20 million iterations each, and
prints the elapsed time for each:

```bash
swift run -c release Bench
```

`-c release` matters: a debug build doesn't inline the builder closure away,
so a debug run will (correctly) show the builder path as slower. Always
benchmark in release mode, the same way your app ships.

Baseline numbers from this repo (Apple M4 Pro, macOS 26.5, Swift 6.3.2,
`swift run -c release Bench`):

```
Mapper builder init: 3.504s for 20000000 iterations
Hand-written init (canonical, via ProfileHeaderData itself): 3.452s for 20000000 iterations
Direct memberwise init (no @Mapper involved): 3.472s for 20000000 iterations
```

**Read the *ratio*, not the absolute seconds.** Absolute numbers depend
entirely on your hardware, Swift toolchain, and optimizer version — they
will differ on your machine and will drift over time as compilers change.
What matters, and what this benchmark exists to catch a regression in, is
that all three stay within noise of each other (~1:1:1). If a future
SwiftMapper change makes the builder path measurably slower than the other
two, that's a real regression worth investigating.

## Compile-time cost: the dimension that actually scales with your project

Runtime cost doesn't scale with how many types you annotate with `@Mapper`
— it's zero regardless. What *does* scale is macro-expansion time: every
`@Mapper` usage is expanded once per build by the Swift compiler, and that
expansion's cost is what's relevant to adopting SwiftMapper broadly across
a project with many mapped types.

As of this doc, `@Mapper`'s expansion builds its two generated members (the
builder `init` and the nested `Builder` enum) entirely out of typed
`SwiftSyntax` nodes — never through string interpolation or
`DeclSyntax(stringLiteral:)`. Earlier versions built them as large,
interpolated Swift-source strings and re-parsed that text on every single
expansion, with cost scaling with each mapped type's field count and type
complexity. That re-parsing is now gone entirely: no text is generated or
re-parsed at expansion time, no matter how many fields a type has or how
complex their types are.

There isn't a single meaningful number to report here (unlike the runtime
benchmark above) — compile-time impact depends on your project's size, how
many types use `@Mapper`, and your build configuration (incremental vs.
clean, whole-module vs. per-file). If you want to track this for your own
project, compare clean build times with and without `@Mapper` usages, or
profile a build with `-Xfrontend -debug-time-function-bodies` /
`-Xfrontend -warn-long-expansion-requests` and look for `@Mapper` in the
output.

## When to re-run this

Re-run `swift run -c release Bench` after any change to `MapperMacro.swift`
or to `Boxed`/`Rule`, and confirm the three numbers stay close together. If
you're proposing a change that intentionally trades runtime cost for
something else (unlikely, given the design — flag it in your PR if so),
update the baseline numbers in this doc alongside your change.
