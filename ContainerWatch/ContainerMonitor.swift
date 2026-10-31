import Foundation

/// Lists running containers, groups them by the app that launched them, and checks registries for updates.
///
/// Containers that belong to one app (same network, e.g. `backend.penpot`, `frontend.penpot`) are versioned as a
/// unit: the app's own images must move to a release published for *all* of them, and third-party dependencies
/// the app pins (Postgres, Valkey, …) are reported but never offered as independent updates.
actor ContainerMonitor {
    private let registry = RegistryClient()
    private var cache: [String: (date: Date, info: UpdateInfo)] = [:]
    private var appCache: [String: (date: Date, group: AppGroup)] = [:]

    /// Cached registry results younger than `maxAge` seconds are reused unless `force` is set.
    func snapshot(force: Bool, maxAge: TimeInterval) async throws -> Snapshot {
        let containers = try await ContainerCLI.listRunning()

        var byApp: [String: [RunningContainer]] = [:]
        var loose: [RunningContainer] = []
        for container in containers {
            if let app = container.appName { byApp[app, default: []].append(container) } else { loose.append(container) }
        }

        var apps: [AppGroup] = []
        for (name, members) in byApp {
            guard let core = components(of: members) else {
                loose += members   // nothing in this network is released together; treat each on its own
                continue
            }
            let deps = members.filter { !core.contains($0) }
            let key = "\(name)|" + members.map { "\($0.imageReference)|\($0.digest ?? "")" }.sorted().joined(separator: ",")
            if !force, let hit = appCache[key], Date().timeIntervalSince(hit.date) < maxAge {
                apps.append(hit.group)
                continue
            }
            let group = await checkApp(name: name, core: core, dependencies: deps)
            if !group.components.contains(where: { $0.info.kind == .error }) { appCache[key] = (Date(), group) }
            apps.append(group)
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let standalone = await statuses(for: loose, force: force, maxAge: maxAge)
        return Snapshot(apps: apps, standalone: standalone)
    }

    // MARK: - Apps

    /// The containers that are the app itself: the largest set of images from one non-official namespace
    /// (e.g. everything under `docker.io/penpotapp/`). Returns nil if no such set exists.
    private func components(of members: [RunningContainer]) -> [RunningContainer]? {
        func namespace(_ container: RunningContainer) -> String {
            let image = container.image
            return image.registry + "/" + image.repository.split(separator: "/").dropLast().joined(separator: "/")
        }
        return Dictionary(grouping: members, by: namespace)
            .filter { !$0.key.hasSuffix("/library") && $0.value.count >= 2 }
            .max { $0.value.count < $1.value.count }?
            .value
    }

    private func checkApp(name: String, core: [RunningContainer], dependencies: [RunningContainer]) async -> AppGroup {
        let core = core.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        let deps = dependencies
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            .map {
                ContainerStatus(
                    container: $0,
                    info: UpdateInfo(kind: .managed, message: "Version is set by \(name)"),
                    role: .dependency, app: name)
            }

        let current = mostCommon(core.compactMap { $0.image.tag }) ?? "unknown"

        func group(_ infos: [UpdateInfo], latest: String?, major: String?, notes: [String]) -> AppGroup {
            let components = zip(core, infos).map { ContainerStatus(container: $0, info: $1, role: .component, app: name) }
            return AppGroup(
                name: name, components: components, dependencies: deps, currentVersion: current,
                latestVersion: latest, newerMajorVersion: major, notes: notes)
        }

        // Tags like `latest` carry no release number, so fall back to checking each image on its own.
        guard let currentVersion = TagVersion(current) else {
            var infos: [UpdateInfo] = []
            for container in core { infos.append(await check(container)) }
            return group(infos, latest: nil, major: nil, notes: [])
        }

        do {
            // For each component repository: the newer releases of the same shape that it publishes.
            var releases: [String: Set<String>] = [:]
            for container in core where releases[container.image.name] == nil {
                releases[container.image.name] = Set(try await registry.tags(for: container.image).filter {
                    guard let v = TagVersion($0) else { return false }
                    return v.sameShape(as: currentVersion) && v > currentVersion && plausible(v, over: currentVersion)
                })
            }
            let sets = Array(releases.values)
            let union = sets.reduce(into: Set<String>()) { $0.formUnion($1) }
            // Only a release every component has published is safe to recommend.
            let common = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }

            let candidates = common.compactMap { tag in TagVersion(tag).map { (tag, $0) } }
            let sameMajor = candidates.filter { $0.1.parts[0] == currentVersion.parts[0] }.max { $0.1 < $1.1 }?.0
            let newerMajor = candidates.filter { $0.1.parts[0] != currentVersion.parts[0] }.max { $0.1 < $1.1 }?.0

            var notes: [String] = []
            let newestCommon = candidates.map(\.1).max()
            if let partial = union.subtracting(common).compactMap({ tag in TagVersion(tag).map { (tag, $0) } }).max(by: { $0.1 < $1.1 }),
               newestCommon == nil || partial.1 > newestCommon! {
                let missing = releases.filter { !$0.value.contains(partial.0) }.keys
                    .map { $0.split(separator: "/").last.map(String.init) ?? $0 }.sorted()
                notes.append("\(partial.0) is out for some components but not yet for: \(missing.joined(separator: ", ")).")
            }
            for container in core where container.image.tag != current {
                notes.append("\(container.id) is on \(container.image.tag ?? "a pinned digest") while the rest are on \(current).")
            }

            let target = sameMajor ?? newerMajor ?? current
            let infos = core.map { container in
                container.image.tag == target
                    ? UpdateInfo(kind: .upToDate)
                    : UpdateInfo(kind: .newVersion, latestTag: target, newerMajorTag: sameMajor != nil ? newerMajor : nil)
            }
            return group(infos, latest: sameMajor ?? newerMajor, major: sameMajor != nil ? newerMajor : nil, notes: notes)
        } catch {
            let info = UpdateInfo(kind: .error, message: error.localizedDescription)
            return group(core.map { _ in info }, latest: nil, major: nil, notes: [])
        }
    }

    private func mostCommon(_ values: [String]) -> String? {
        Dictionary(grouping: values, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    // MARK: - Standalone containers

    private func statuses(for containers: [RunningContainer], force: Bool, maxAge: TimeInterval) async -> [ContainerStatus] {
        let groups = Dictionary(grouping: containers) { "\($0.imageReference)|\($0.digest ?? "")" }

        var infos: [String: UpdateInfo] = [:]
        var toCheck: [(key: String, container: RunningContainer)] = []
        for (key, members) in groups {
            if !force, let hit = cache[key], Date().timeIntervalSince(hit.date) < maxAge {
                infos[key] = hit.info
            } else {
                toCheck.append((key, members[0]))
            }
        }

        let checked = await withTaskGroup(of: (String, UpdateInfo).self) { group in
            for item in toCheck {
                group.addTask { (item.key, await self.check(item.container)) }
            }
            var out: [String: UpdateInfo] = [:]
            for await (key, info) in group { out[key] = info }
            return out
        }
        for (key, info) in checked {
            infos[key] = info
            if info.kind != .error { cache[key] = (Date(), info) }
        }

        return containers
            .map { ContainerStatus(container: $0, info: infos["\($0.imageReference)|\($0.digest ?? "")"]!) }
            .sorted {
                if $0.info.hasUpdate != $1.info.hasUpdate { return $0.info.hasUpdate }
                return $0.container.id.localizedStandardCompare($1.container.id) == .orderedAscending
            }
    }

    private func check(_ container: RunningContainer) async -> UpdateInfo {
        let ref = container.image
        guard let tag = ref.tag else {
            return UpdateInfo(kind: .pinned, message: "Pinned by digest")
        }
        do {
            if let current = TagVersion(tag) {
                let newer = try await registry.tags(for: ref)
                    .compactMap { name in TagVersion(name).map { (name, $0) } }
                    .filter { $0.1.sameShape(as: current) && $0.1 > current && plausible($0.1, over: current) }
                let sameMajor = newer.filter { $0.1.parts[0] == current.parts[0] }.max { $0.1 < $1.1 }
                let newerMajor = newer.filter { $0.1.parts[0] != current.parts[0] }.max { $0.1 < $1.1 }
                if let best = sameMajor ?? newerMajor {
                    return UpdateInfo(
                        kind: .newVersion,
                        latestTag: best.0,
                        newerMajorTag: sameMajor != nil ? newerMajor?.0 : nil
                    )
                }
            }
            // Floating tags (`latest`, `2`, `15`, …) and the newest numeric tag: has the tag itself moved?
            let remote = try await registry.digest(for: ref, tag: tag)
            if let local = container.digest, local != remote {
                return UpdateInfo(kind: .newBuild, latestTag: tag, latestDigest: remote)
            }
            return UpdateInfo(kind: .upToDate)
        } catch {
            return UpdateInfo(kind: .error, message: error.localizedDescription)
        }
    }

    /// Filters out tags that are really build numbers or commit hashes (e.g. `1234567` next to `15`).
    private func plausible(_ candidate: TagVersion, over current: TagVersion) -> Bool {
        candidate.parts[0] <= max(current.parts[0] * 10, current.parts[0] + 50)
    }
}
