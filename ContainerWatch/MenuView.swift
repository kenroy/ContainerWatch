import SwiftUI
import AppKit
import ServiceManagement

struct MenuView: View {
    let store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            intervalSettings
            Divider()
            footer
        }
        .frame(width: 440)
        .task { await store.refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Containers").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isChecking { ProgressView().controlSize(.small) }
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Check registries now")
            .disabled(store.isChecking)
        }
        .padding(12)
    }

    private var summary: String {
        let running = "\(store.snapshot.all.count) running"
        let updates = store.updateCount == 0 ? "all up to date" : "\(store.updateCount) update\(store.updateCount == 1 ? "" : "s") available"
        var text = store.snapshot.isEmpty ? "No running containers" : "\(running) · \(updates)"
        if let date = store.lastChecked {
            text += " · checked \(date.formatted(.relative(presentation: .named)))"
        }
        return text
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if store.snapshot.isEmpty {
            Text(store.isChecking ? "Checking…" : "Nothing is running. Start a container and it will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.snapshot.apps) { app in
                        AppGroupView(group: app)
                        Divider()
                    }
                    if !store.snapshot.apps.isEmpty && !store.snapshot.standalone.isEmpty {
                        Text("Other containers")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                    }
                    ForEach(store.snapshot.standalone) { row in
                        ContainerRowView(row: row)
                        if row.id != store.snapshot.standalone.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 480)
        }
    }

    private var intervalSettings: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
            Text("Check for updates every").font(.callout)
            Picker("Check interval", selection: $store.preset) {
                ForEach(IntervalPreset.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if store.preset == .custom {
                TextField("", value: $store.customValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Picker("Unit", selection: $store.customUnit) {
                    ForEach(IntervalUnit.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 0)
            }
            Toggle("Launch at startup", isOn: $launchAtLogin)
                .font(.callout)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = SMAppService.mainApp.status == .requiresApproval
                ? "Approve ContainerWatch in System Settings › General › Login Items." : nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var footer: some View {
        HStack {
            Button("Copy report") { copy(Report.text(store.snapshot)) }
            Button("Show updates.json") {
                NSWorkspace.shared.activateFileViewerSelecting([Report.jsonURL])
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(12)
    }
}

private struct ContainerRowView: View {
    let row: ContainerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AppIcon(reference: row.container.imageReference, size: 24)
                Text(row.container.id).font(.system(.body, weight: .semibold))
                Spacer()
                Text(badge).font(.caption.weight(.medium)).foregroundStyle(color)
            }
            Text(row.image.name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    label("Current")
                    versionText(row.currentTag, digest: shortDigest(row.container.digest))
                }
                switch row.info.kind {
                case .newVersion:
                    GridRow {
                        label("Latest")
                        versionText(row.info.latestTag ?? "?", digest: nil).foregroundStyle(.green)
                    }
                    if let major = row.info.newerMajorTag {
                        GridRow {
                            label("New major")
                            versionText(major, digest: nil).foregroundStyle(.orange)
                        }
                    }
                case .newBuild:
                    GridRow {
                        label("Latest")
                        versionText(row.currentTag + " (rebuilt)", digest: shortDigest(row.info.latestDigest))
                            .foregroundStyle(.green)
                    }
                case .error:
                    GridRow {
                        label("Error")
                        Text(row.info.message ?? "Unknown error").font(.caption).foregroundStyle(.orange)
                    }
                case .pinned:
                    GridRow {
                        label("Status")
                        Text("Pinned by digest — not checked").font(.caption).foregroundStyle(.secondary)
                    }
                case .upToDate, .managed:
                    EmptyView()
                }
            }

            if let pull = row.pullReference {
                HStack(spacing: 6) {
                    Text(pull)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Copy") { copy(pull) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Copy the image reference to pull")
                }
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                PullControl(refs: [pull])
            }
        }
        .padding(12)
    }

    private var color: Color {
        switch row.info.kind {
        case .newVersion, .newBuild: .green
        case .upToDate, .managed, .pinned: .secondary
        case .error: .orange
        }
    }

    private var badge: String {
        switch row.info.kind {
        case .newVersion: "Update available"
        case .newBuild: "New build available"
        case .upToDate: "Up to date"
        case .managed: "Managed"
        case .pinned: "Pinned"
        case .error: "Check failed"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func versionText(_ version: String, digest: String?) -> some View {
        HStack(spacing: 6) {
            Text(version).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            if let digest {
                Text(digest).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }
}

func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
