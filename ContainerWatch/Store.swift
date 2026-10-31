import Foundation
import Observation

@MainActor @Observable
final class Store {
    static let shared = Store()

    var snapshot = Snapshot()
    var isChecking = false
    var lastChecked: Date?
    var errorMessage: String?

    var preset: IntervalPreset { didSet { settingsChanged() } }
    var customValue: Int { didSet { settingsChanged() } }
    var customUnit: IntervalUnit { didSet { settingsChanged() } }

    /// Apps with an update plus standalone containers with one; an app counts once however many components it has.
    var updateCount: Int { snapshot.updateCount }

    enum PullState: Equatable {
        case pulling(done: Int, total: Int, current: String)
        case done
        case failed(String)
    }

    /// Progress of image pulls, keyed by `pullKey(for:)`. Kept here so a pull continues if the popover closes.
    var pulls: [String: PullState] = [:]

    static func pullKey(for refs: [String]) -> String { refs.joined(separator: ",") }

    /// Pulls the images one after another and stops at the first failure.
    func pull(_ refs: [String]) async {
        let key = Self.pullKey(for: refs)
        if case .pulling = pulls[key] { return }
        for (index, ref) in refs.enumerated() {
            pulls[key] = .pulling(done: index, total: refs.count, current: ref)
            do {
                try await ContainerCLI.pull(ref)
            } catch {
                pulls[key] = .failed("\(ref): \(error.localizedDescription)")
                return
            }
        }
        pulls[key] = .done
    }

    /// How long a registry result is trusted before the image is checked again.
    var checkInterval: TimeInterval {
        preset.seconds ?? TimeInterval(max(customValue, 1)) * customUnit.seconds
    }

    private let monitor = ContainerMonitor()
    private var loop: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        preset = IntervalPreset(rawValue: defaults.string(forKey: "intervalPreset") ?? "") ?? .hour1
        customValue = max(defaults.integer(forKey: "customValue"), 1)
        customUnit = IntervalUnit(rawValue: defaults.string(forKey: "customUnit") ?? "") ?? .hours
    }

    private func settingsChanged() {
        defaults.set(preset.rawValue, forKey: "intervalPreset")
        defaults.set(max(customValue, 1), forKey: "customValue")
        defaults.set(customUnit.rawValue, forKey: "customUnit")
        // Apply a shorter interval right away; cached results older than it are re-checked.
        if loop != nil { Task { await refresh() } }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await refresh()
                // The local container list is cheap, so it refreshes every 5 minutes at most;
                // registry lookups only happen once a cached result is older than `checkInterval`.
                try? await Task.sleep(for: .seconds(min(checkInterval, 300)))
            }
        }
    }

    /// `force` bypasses the registry cache.
    func refresh(force: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            snapshot = try await monitor.snapshot(force: force, maxAge: checkInterval)
            errorMessage = nil
            lastChecked = Date()
            Report.export(snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Used by `--report` / `--json` command-line mode.
    static func oneShot() async throws -> Snapshot {
        try await ContainerMonitor().snapshot(force: true, maxAge: 0)
    }
}
