import SwiftUI
import AppKit
import CryptoKit

/// Finds and caches a logo for each image, so rows can show the application's icon.
///
/// Sources, in order: Docker's official-image logos (`docker-library/docs`) for `library/*` images, then the
/// GitHub owner named in the image's `org.opencontainers.image.source` / `.url` label. Images with neither
/// keep the generic box icon.
@MainActor @Observable
final class IconStore {
    static let shared = IconStore()

    private(set) var images: [String: NSImage] = [:]
    private var attempted: Set<String> = []

    private let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ContainerWatch/icons", isDirectory: true)

    func load(reference: String) async {
        let ref = ImageReference(reference)
        let key = ref.name
        guard images[key] == nil, attempted.insert(key).inserted else { return }

        let file = cacheDirectory.appendingPathComponent(
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            images[key] = image
            return
        }

        var candidates: [URL] = []
        if ref.registry == "docker.io", ref.repository.hasPrefix("library/") {
            let name = ref.repository.dropFirst("library/".count)
            if let url = URL(string: "https://raw.githubusercontent.com/docker-library/docs/master/\(name)/logo.png") {
                candidates.append(url)
            }
        }
        let labels = await ContainerCLI.imageLabels(reference)
        for label in ["org.opencontainers.image.source", "org.opencontainers.image.url"] {
            if let owner = labels[label].flatMap(Self.githubOwner),
               let url = URL(string: "https://github.com/\(owner).png?size=96") {
                candidates.append(url)
                break
            }
        }

        for url in candidates {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { continue }
            images[key] = image
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return
        }
    }

    private static func githubOwner(_ string: String) -> String? {
        guard let url = URL(string: string), let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com",
              let owner = url.pathComponents.dropFirst().first,
              owner.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return owner
    }
}

/// The application's logo on a light tile, or a generic box while it loads or if none was found.
struct AppIcon: View {
    let reference: String
    var size: CGFloat = 22

    var body: some View {
        let name = ImageReference(reference).name
        Group {
            if let image = IconStore.shared.images[name] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.08)
                    .background(Color.white)
            } else {
                Image(systemName: "shippingbox")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(.secondary)
                    .background(.quaternary.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .task(id: name) { await IconStore.shared.load(reference: reference) }
    }
}
