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
/// - A third, additive initializer (same `convenience`/plain `init` rule as
///   above) that mirrors the canonical initializer's own labels, order, and
///   types exactly, but wraps each field in a plain, independently labeled
///   `() -> T` closure — an ordinary Swift call, not a block-scoped DSL.
///   This *keyword initializer* also delegates straight to the canonical
///   initializer. It's the flatter alternative to the `Builder` closure
///   above for callers who'd rather not open a block: each field is just
///   one more labeled argument.
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
/// The generated keyword initializer, meanwhile, lets the same fields be
/// written as one flat, ordinary call — no block, no capitalized field
/// names:
///
/// ```swift
/// ProfileHeaderData(
///     profile: { .init(url: domain.avatarURL) },
///     fullname: { .loaded(domain.fullName) },
///     nickname: { domain.playerName }
/// )
/// ```
///
/// Both initializers are always generated together and neither replaces the
/// other — pick whichever reads best at a given call site. A field built
/// from a `Rule` needs no `.execute()` in *either* one:
///
/// ```swift
/// ProfileHeaderData(
///     profile: { ProfileConfigurationRule(input: domain.avatarURL) },
///     fullname: { .loaded(domain.fullName) },
///     nickname: { domain.playerName }
/// )
/// ```
///
/// Each keyword-initializer parameter is independently marked with its own
/// per-field `@resultBuilder` (a private, per-position `RuleBuilder<T>`
/// typealias the macro also generates — an implementation detail, never
/// meant to be referenced directly), so every field's closure resolves a
/// plain value or a child `Rule` on its own, the same one-level resolution
/// `Rule.body` already gets from `RuleBuilder`. Because that resolution is
/// entirely per-closure, there's no combinatorial blow-up across fields no
/// matter how many of them mix plain values and rules in the same call —
/// this only works because each field is independently attributed, not
/// because `@Mapper` special-cases `Rule` at the whole-initializer level.
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
/// - The canonical initializer must declare **at most 32 fields** — the
///   hard limit on how many fields the generated keyword initializer can
///   cover (see `keywordFieldBuilderMaxFieldCount` in `MapperMacro.swift`
///   for why this is a fixed cap rather than an unbounded list). The
///   generated `Builder`-DSL initializer has no such limit.
@attached(
    member,
    names: named(init), named(Builder),
        named(__MapperFieldBuilder0), named(__MapperFieldBuilder1), named(__MapperFieldBuilder2), named(__MapperFieldBuilder3),
        named(__MapperFieldBuilder4), named(__MapperFieldBuilder5), named(__MapperFieldBuilder6), named(__MapperFieldBuilder7),
        named(__MapperFieldBuilder8), named(__MapperFieldBuilder9), named(__MapperFieldBuilder10), named(__MapperFieldBuilder11),
        named(__MapperFieldBuilder12), named(__MapperFieldBuilder13), named(__MapperFieldBuilder14), named(__MapperFieldBuilder15),
        named(__MapperFieldBuilder16), named(__MapperFieldBuilder17), named(__MapperFieldBuilder18), named(__MapperFieldBuilder19),
        named(__MapperFieldBuilder20), named(__MapperFieldBuilder21), named(__MapperFieldBuilder22), named(__MapperFieldBuilder23),
        named(__MapperFieldBuilder24), named(__MapperFieldBuilder25), named(__MapperFieldBuilder26), named(__MapperFieldBuilder27),
        named(__MapperFieldBuilder28), named(__MapperFieldBuilder29), named(__MapperFieldBuilder30), named(__MapperFieldBuilder31)
)
public macro Mapper() = #externalMacro(module: "SwiftMapperMacros", type: "MapperMacro")

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
