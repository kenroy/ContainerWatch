import SwiftUI

/// One app (e.g. Penpot) and the containers it launched, shown with a single shared version.
struct AppGroupView: View {
    let group: AppGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AppIcon(reference: group.components.first?.container.imageReference ?? "", size: 28)
                Text(group.displayName).font(.system(.body, weight: .semibold))
                Spacer()
                Text(badge).font(.caption.weight(.medium)).foregroundStyle(color)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    label("Current")
                    version(group.currentVersion)
                }
                if let latest = group.latestVersion, group.hasUpdate {
                    GridRow {
                        label("Latest")
                        version(latest).foregroundStyle(.green)
                    }
                }
                if let major = group.newerMajorVersion {
                    GridRow {
                        label("New major")
                        version(major).foregroundStyle(.orange)
                    }
                }
            }

            ForEach(group.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if group.hasUpdate, !group.pullReferences.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Update all \(group.pullReferences.count) components together")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy all") { copy(group.pullReferences.joined(separator: "\n")) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    ForEach(group.pullReferences, id: \.self) { ref in
                        Text(ref)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    PullControl(refs: group.pullReferences).padding(.top, 4)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            section("Components", rows: group.components)
            if !group.dependencies.isEmpty {
                section("Dependencies — version set by \(group.displayName), not updated separately", rows: group.dependencies)
            }
        }
        .padding(12)
    }

    private func section(_ title: String, rows: [ContainerStatus]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Text(row.container.id).font(.callout)
                    Spacer()
                    Text(row.currentTag)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(row.info.hasUpdate ? Color.orange : Color.secondary)
                }
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 2)
        }
        .padding(.leading, 14)
    }

    private var color: Color {
        if group.components.contains(where: { $0.info.kind == .error }) { return .orange }
        return group.hasUpdate ? .green : .secondary
    }

    private var badge: String {
        if group.components.contains(where: { $0.info.kind == .error }) { return "Check failed" }
        return group.hasUpdate ? "Update available" : "Up to date"
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func version(_ text: String) -> some View {
        Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
    }
}
