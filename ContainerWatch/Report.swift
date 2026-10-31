import Foundation

/// Text and JSON renderings of a scan, for the UI, the clipboard and scripts.
enum Report {
    static var exportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContainerWatch", isDirectory: true)
    }

    static var jsonURL: URL { exportDirectory.appendingPathComponent("updates.json") }

    static func text(_ snapshot: Snapshot) -> String {
        guard !snapshot.isEmpty else { return "No running containers.\n" }
        var lines: [String] = []

        for app in snapshot.apps {
            if let latest = app.latestVersion, app.hasUpdate {
                lines.append("UPDATE  app \(app.name)  \(app.currentVersion) -> \(latest)")
                for ref in app.pullReferences { lines.append("        container image pull \(ref)") }
                if let major = app.newerMajorVersion {
                    lines.append("        newer major \(major) also exists; update all components together")
                }
            } else if app.hasUpdate {
                lines.append("UPDATE  app \(app.name)  \(app.currentVersion)")
                for row in app.components where row.info.hasUpdate {
                    if let ref = row.pullReference { lines.append("        container image pull \(ref)") }
                }
            } else if app.components.contains(where: { $0.info.kind == .error }) {
                let message = app.components.first { $0.info.kind == .error }?.info.message ?? ""
                lines.append("error   app \(app.name)  \(app.currentVersion)  \(message)")
            } else {
                lines.append("ok      app \(app.name)  \(app.currentVersion)")
            }
            for note in app.notes { lines.append("        note: \(note)") }
            if !app.dependencies.isEmpty {
                lines.append("        dependencies (version set by \(app.name), not updated separately):")
                for dep in app.dependencies {
                    lines.append("          \(dep.container.id)  \(dep.container.imageReference)")
                }
            }
        }

        for row in snapshot.standalone {
            let image = row.image.name
            switch row.info.kind {
            case .newVersion:
                lines.append("UPDATE  \(row.container.id)  \(image)  \(row.currentTag) -> \(row.info.latestTag ?? "?")")
                if let ref = row.pullReference { lines.append("        container image pull \(ref)") }
                if let major = row.info.newerMajorTag, let ref = row.majorPullReference {
                    lines.append("        newer major \(major): container image pull \(ref)")
                }
            case .newBuild:
                lines.append("UPDATE  \(row.container.id)  \(image):\(row.currentTag)  new build "
                    + "\(shortDigest(row.container.digest) ?? "?") -> \(shortDigest(row.info.latestDigest) ?? "?")")
                if let ref = row.pullReference { lines.append("        container image pull \(ref)") }
            case .upToDate, .managed:
                lines.append("ok      \(row.container.id)  \(image):\(row.currentTag)")
            case .pinned:
                lines.append("pinned  \(row.container.id)  \(row.container.imageReference)")
            case .error:
                lines.append("error   \(row.container.id)  \(image):\(row.currentTag)  \(row.info.message ?? "")")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func json(_ snapshot: Snapshot) -> Data {
        func item(_ row: ContainerStatus) -> [String: Any] {
            [
                "container": row.container.id,
                "app": row.app ?? NSNull(),
                "role": row.role.rawValue,
                "image": row.image.name,
                "currentReference": row.container.imageReference,
                "currentTag": row.image.tag ?? NSNull(),
                "currentDigest": row.container.digest ?? NSNull(),
                "status": row.info.kind.rawValue,
                "updateAvailable": row.info.hasUpdate,
                "latestTag": row.info.latestTag ?? NSNull(),
                "latestDigest": row.info.latestDigest ?? NSNull(),
                "newerMajorTag": row.info.newerMajorTag ?? NSNull(),
                "pullReference": row.pullReference ?? NSNull(),
                "newerMajorPullReference": row.majorPullReference ?? NSNull(),
                "error": row.info.kind == .error ? (row.info.message ?? "") : NSNull(),
            ]
        }
        let apps: [[String: Any]] = snapshot.apps.map { app in
            [
                "name": app.name,
                "currentVersion": app.currentVersion,
                "latestVersion": app.latestVersion ?? NSNull(),
                "newerMajorVersion": app.newerMajorVersion ?? NSNull(),
                "updateAvailable": app.hasUpdate,
                "notes": app.notes,
                "pullReferences": app.pullReferences,
                "components": app.components.map(item),
                "dependencies": app.dependencies.map(item),
            ]
        }
        let root: [String: Any] = [
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "apps": apps,
            "standalone": snapshot.standalone.map(item),
            "containers": snapshot.all.map(item),
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Writes `updates.json` so scripts can read the latest scan without launching the app.
    static func export(_ snapshot: Snapshot) {
        try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        try? json(snapshot).write(to: jsonURL, options: .atomic)
    }
}
