import Foundation

/// A parsed OCI image reference such as `docker.io/penpotapp/mcp:2.18`.
struct ImageReference: Hashable, Sendable {
    let registry: String
    let repository: String
    let tag: String?
    let digest: String?

    init(_ raw: String) {
        var rest = raw
        var digest: String?
        if let at = rest.firstIndex(of: "@") {
            digest = String(rest[rest.index(after: at)...])
            rest = String(rest[..<at])
        }
        var tag: String?
        if let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("/") {
            tag = String(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        var parts = rest.split(separator: "/").map(String.init)
        var registry = "docker.io"
        if parts.count > 1, parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost" {
            registry = parts.removeFirst()
        }
        var repository = parts.joined(separator: "/")
        if registry == "docker.io", !repository.contains("/") {
            repository = "library/" + repository
        }
        self.registry = registry
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// `registry/repository`, without a tag.
    var name: String { "\(registry)/\(repository)" }

    func reference(tag: String) -> String { "\(name):\(tag)" }
}

/// A numeric tag such as `2.18`, `v1.4.2` or `16-alpine`, split so tags of the same shape can be ordered.
struct TagVersion: Comparable, Sendable {
    let prefix: String
    let parts: [Int]
    let suffix: String

    init?(_ tag: String) {
        var chars = Substring(tag)
        var prefix = ""
        if let first = chars.first, first == "v" || first == "V" {
            prefix = String(first)
            chars = chars.dropFirst()
        }
        let numeric = chars.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        var run = numeric
        while run.last == "." { run = run.dropLast() }
        guard let first = run.first, first.isNumber else { return nil }
        let parts = run.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.contains(nil) else { return nil }
        self.prefix = prefix
        self.parts = parts.compactMap { $0 }
        self.suffix = String(chars.dropFirst(run.count))
    }

    func sameShape(as other: TagVersion) -> Bool {
        prefix == other.prefix && suffix == other.suffix && parts.count == other.parts.count
    }

    static func < (a: TagVersion, b: TagVersion) -> Bool {
        a.parts.lexicographicallyPrecedes(b.parts)
    }
}

struct RunningContainer: Sendable, Hashable {
    let id: String
    let imageReference: String
    let digest: String?
    let network: String?

    var image: ImageReference { ImageReference(imageReference) }

    /// The app this container belongs to: its network (e.g. `penpot`), else the suffix of an `name.app` id.
    var appName: String? {
        if let network, network != "default" { return network }
        if let dot = id.lastIndex(of: "."), dot != id.startIndex { return String(id[id.index(after: dot)...]) }
        return nil
    }
}

struct UpdateInfo: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// `managed`: a dependency whose version is dictated by its app, so it is never updated on its own.
        case upToDate, newVersion, newBuild, pinned, managed, error
    }

    var kind: Kind
    /// Newest tag in the running tag's major line (or the newest overall if no such tag exists).
    var latestTag: String?
    /// Set when a newer major line exists in addition to `latestTag`.
    var newerMajorTag: String?
    /// Registry digest of the running tag when its contents changed (`newBuild`).
    var latestDigest: String?
    var message: String?

    var hasUpdate: Bool { kind == .newVersion || kind == .newBuild }
}

enum ContainerRole: String, Sendable {
    /// Released together with its app; shares the app's version number.
    case component
    /// Third-party service the app pins (database, cache, proxy…).
    case dependency
    case standalone
}

struct ContainerStatus: Identifiable, Sendable {
    let container: RunningContainer
    let info: UpdateInfo
    var role: ContainerRole = .standalone
    var app: String?

    var id: String { container.id }
    var image: ImageReference { container.image }
    var currentTag: String { image.tag ?? "(pinned by digest)" }

    /// The image reference a script should pull to get the update.
    var pullReference: String? {
        switch info.kind {
        case .newVersion: info.latestTag.map { image.reference(tag: $0) }
        case .newBuild: container.imageReference
        default: nil
        }
    }

    var majorPullReference: String? {
        info.newerMajorTag.map { image.reference(tag: $0) }
    }
}

/// Containers launched by one app (e.g. Penpot), versioned as a unit.
struct AppGroup: Identifiable, Sendable {
    let name: String
    var components: [ContainerStatus]
    var dependencies: [ContainerStatus]
    /// The release the components share, e.g. `2.18`.
    let currentVersion: String
    /// Newest release published for *every* component (same major line, else the newest major).
    let latestVersion: String?
    /// A newer major release, when `latestVersion` is within the current major.
    let newerMajorVersion: String?
    /// Caveats such as a release that isn't published for every component yet.
    let notes: [String]

    var id: String { name }
    var displayName: String { name.prefix(1).uppercased() + name.dropFirst() }
    var hasUpdate: Bool { components.contains { $0.info.hasUpdate } }
    var pullReferences: [String] { components.compactMap(\.pullReference) }
}

struct Snapshot: Sendable {
    var apps: [AppGroup] = []
    var standalone: [ContainerStatus] = []

    var all: [ContainerStatus] { apps.flatMap { $0.components + $0.dependencies } + standalone }
    var updateCount: Int { apps.filter(\.hasUpdate).count + standalone.filter { $0.info.hasUpdate }.count }
    var isEmpty: Bool { apps.isEmpty && standalone.isEmpty }
}

func shortDigest(_ digest: String?) -> String? {
    guard let digest else { return nil }
    let hex = digest.split(separator: ":").last.map(String.init) ?? digest
    return String(hex.prefix(12))
}
