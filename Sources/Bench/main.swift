import Foundation
import SwiftMapper

// A microbenchmark confirming the `@Mapper`-generated builder initializer
// stays a genuinely zero-cost runtime abstraction: constructing a value
// through the generated `Builder` closure should cost the same as calling
// the type's own hand-written initializer directly. See
// `docs/BENCHMARKING.md` for how to run this and how to read its output —
// this file only prints raw timings.

@Mapper
struct ProfileHeaderData: Equatable {
    let id: UUID
    let profile: String
    let fullname: String

    init(profile: String, fullname: String) {
        self.id = .init()
        self.profile = profile
        self.fullname = fullname
    }
}

/// A plain, hand-written equivalent of `ProfileHeaderData`'s memberwise
/// construction path, with no `@Mapper` involved at all — the baseline
/// every other measurement is compared against.
struct HandWrittenProfileHeaderData: Equatable {
    let id: UUID
    let profile: String
    let fullname: String
}

let iterations = 20_000_000

func measure(_ name: String, _ body: () -> Void) {
    let start = Date()
    body()
    let elapsed = Date().timeIntervalSince(start)
    print("\(name): \(String(format: "%.3f", elapsed))s for \(iterations) iterations")
}

var sink = 0

measure("Mapper builder init") {
    for _ in 0..<iterations {
        let value = ProfileHeaderData { Profile, Fullname in
            Profile { "profile" }
            Fullname { "fullname" }
        }
        sink &+= value.profile.utf8.count
    }
}

measure("Hand-written init (canonical, via ProfileHeaderData itself)") {
    for _ in 0..<iterations {
        let value = ProfileHeaderData(profile: "profile", fullname: "fullname")
        sink &+= value.profile.utf8.count
    }
}

measure("Direct memberwise init (no @Mapper involved)") {
    for _ in 0..<iterations {
        let value = HandWrittenProfileHeaderData(id: .init(), profile: "profile", fullname: "fullname")
        sink &+= value.profile.utf8.count
    }
}

// Keeps the loop bodies from being optimized away entirely as dead code.
print("(ignore: \(sink))")
