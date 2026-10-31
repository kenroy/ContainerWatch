import SwiftUI

/// "Pull images…" button with an inline confirmation and progress, for one app or one container.
struct PullControl: View {
    let refs: [String]
    @State private var confirming = false

    private var store: Store { .shared }

    var body: some View {
        HStack(spacing: 6) {
            switch store.pulls[Store.pullKey(for: refs)] {
            case .pulling(let done, let total, let current):
                ProgressView().controlSize(.small)
                Text("Pulling \(done + 1) of \(total): \(current.split(separator: "/").last ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            case .done:
                Label("Pulled. Restart the containers to use the new version.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(3)
                Spacer(minLength: 0)
                Button("Retry") { start() }.buttonStyle(.borderless).font(.caption)
            case nil:
                if confirming {
                    Text("Pull \(refs.count) image\(refs.count == 1 ? "" : "s")?").font(.caption)
                    Button("Pull") { confirming = false; start() }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { confirming = false }.buttonStyle(.borderless).font(.caption)
                } else {
                    Button("Pull \(refs.count == 1 ? "image" : "\(refs.count) images")…") { confirming = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Download the new image(s). Running containers are not changed.")
                }
            }
        }
    }

    private func start() {
        let refs = refs
        Task { await Store.shared.pull(refs) }
    }
}
