/// Generates a composable, type-safe "field builder" initializer for a struct.
///
/// Attach `@Mapper` to a struct that already declares exactly one explicit
/// initializer (its "canonical" initializer — the one that sets every stored
/// property). The macro reads that initializer's parameter list and adds:
///
/// - A nested `@resultBuilder` enum (named `<Type>Builder`) whose
///   `buildBlock` mirrors the canonical initializer's parameters in order.
/// - A second, additive initializer that takes a `@<Type>Builder` closure
///   with one labeled `Boxed<T>` parameter per field, so callers can write
///   the field's mapping logic as a small, labeled DSL instead of a single
///   flat initializer call.
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
///         @ProfileHeaderDataBuilder
///         _ creation: (
///             _ Profile: Boxed<TdsAvatar.Configuration>,
///             _ Fullname: Boxed<DataState<String>>,
///             _ Nickname: Boxed<String>
///         ) -> Self
///     ) {
///         self = creation(.init(), .init(), .init())
///     }
///
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
/// - `@Mapper` must be attached to a `struct`.
/// - The struct must declare **exactly one** explicit initializer, *or*, if
///   it declares more than one, exactly one of them must be marked
///   `@MapperCanonical`. That initializer defines the fields, order, types,
///   and labels used by the generated builder — the macro does not inspect
///   stored properties directly, so any property not part of that
///   initializer's parameter list (an `id` given a fresh default value, for
///   example) is left alone. See `MapperCanonical` for the multi-initializer
///   case.
/// - Initializer parameters must be simple `label: Type` parameters — no
///   variadics, and no parameter packs. Default values on the canonical
///   initializer are ignored by the generated builder (every field must be
///   supplied there).
/// - Generic structs are supported, including `where` clauses and
///   constraints on the generic parameters — because `@Mapper` is a
///   *member* macro, the builder initializer and its nested
///   `<Type>Builder` enum are generated lexically inside the struct's own
///   body, so they see its generic parameters the same way any other
///   member would.
@attached(member, names: arbitrary)
public macro Mapper() = #externalMacro(module: "SwiftMapperMacros", type: "MapperMacro")

/// Marks the initializer that `@Mapper` should treat as canonical when the
/// attached struct declares more than one initializer.
///
/// `@Mapper` normally requires a struct to declare **exactly one**
/// initializer, since that initializer's parameter list defines every field
/// the generated builder covers. Real-world structs sometimes need more than
/// one initializer, though — a synthesized `Decodable` initializer, or a
/// convenience initializer that call sites needing the builder never use.
/// Attach `@MapperCanonical` to the initializer that should define the
/// generated builder's fields, and `@Mapper` uses it while leaving every
/// other initializer untouched:
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
/// It has no effect (and isn't required) when a struct declares only a
/// single initializer; it only matters once there's more than one to choose
/// from. `@Mapper` reports a compile-time error if a struct with multiple
/// initializers marks none or more than one of them `@MapperCanonical`.
@attached(peer, names: arbitrary)
public macro MapperCanonical() = #externalMacro(module: "SwiftMapperMacros", type: "MapperCanonicalMacro")
