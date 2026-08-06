/// Element-wise composition support for `Array`-typed `Boxed<T>` fields.
///
/// A `[Element]` field already works with plain `Boxed<T>` — nothing about
/// `@Mapper`'s generated builder needs to change for that, since `Boxed<T>`
/// is already generic over any `T`, arrays included:
///
/// ```swift
/// Items { domain.items.map(ItemViewModel.init) }
/// ```
///
/// What that doesn't give you is a labeled way to map a *different* source
/// collection element-by-element without dropping to a bare `.map { }` call.
/// This overload of `callAsFunction` closes that gap without touching the
/// macro at all: it stays purely additive on top of the same `Boxed<T>`
/// used everywhere else, so a `[Element]` field can be built the same
/// labeled-DSL way as any other field:
///
/// ```swift
/// Items(mapping: domain.items) { domainItem in
///     ItemViewModel(id: domainItem.id, title: domainItem.title.capitalized)
/// }
/// ```
extension Boxed {
    /// Builds an `Array`-typed field by mapping each element of `source`
    /// through `transform`, in order.
    ///
    /// This only participates in overload resolution when this `Boxed<T>`'s
    /// field type `T` is itself an `Array<Element>` — for any other field
    /// type, only the plain `callAsFunction(_:)` closure form applies.
    @inlinable
    public func callAsFunction<Source: Sequence, Element>(
        mapping source: Source,
        _ transform: (Source.Element) -> Element
    ) -> [Element] where T == [Element] {
        source.map(transform)
    }

    /// The same as the overload above, but for a `transform` that constructs a `Rule`
    /// per element instead of the mapped value directly — the array-field equivalent of
    /// `Boxed`'s own `callAsFunction<R: Rule>(_ creation: () -> R)` overload. Lets an
    /// element-wise collection field read a per-element `Rule` construction directly,
    /// with no trailing `.execute()` at each element:
    ///
    /// ```swift
    /// Items(mapping: domain.items) { domainItem in
    ///     ItemRule(input: domainItem)
    /// }
    /// ```
    ///
    /// Never ambiguous with the overload above: `transform`'s return type is either a
    /// concrete `Element` value or a concrete `Rule`, never both, so overload resolution
    /// always has exactly one match.
    @inlinable
    public func callAsFunction<Source: Sequence, R: Rule>(
        mapping source: Source,
        _ transform: (Source.Element) -> R
    ) -> [R.Output] where T == [R.Output] {
        source.map { transform($0).execute() }
    }
}
