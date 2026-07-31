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
/// branch just needs to produce the same field type — and a plain `if` (no
/// `else`) works for fields whose declared type is already `Optional`. See
/// the generated `buildEither`/`buildOptional` functions above.
///
/// ## Requirements (v1)
///
/// - `@Mapper` must be attached to a `struct`.
/// - The struct must declare **exactly one** explicit initializer. That
///   initializer defines the fields, order, types, and labels used by the
///   generated builder — the macro does not inspect stored properties
///   directly, so any property not part of that initializer's parameter
///   list (an `id` given a fresh default value, for example) is left alone.
/// - Initializer parameters must be simple `label: Type` parameters — no
///   variadics, and no parameter packs. Default values on the canonical
///   initializer are ignored by the generated builder (every field must be
///   supplied there).
/// - Generic structs are not yet supported.
@attached(member, names: arbitrary)
public macro Mapper() = #externalMacro(module: "SwiftMapperMacros", type: "MapperMacro")
