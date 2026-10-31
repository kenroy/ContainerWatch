import Foundation

enum ContainerCLIError: LocalizedError {
    case notInstalled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The `container` CLI was not found. Install Apple's container tool first."
        case .failed(let message): message
        }
    }
}

/// Thin wrapper around Apple's `container` command-line tool.
enum ContainerCLI {
    static func locate() -> URL? {
        let fixed = ["/opt/homebrew/bin/container", "/usr/local/bin/container", "/usr/bin/container"]
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/container" }
        return (fixed + fromPath)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func listRunning() async throws -> [RunningContainer] {
        let data = try await run(["list", "--format", "json"])
        let raw = try JSONDecoder().decode([RawContainer].self, from: data)
        return raw
            .filter { ($0.status?.state ?? "running") == "running" }
            .map {
                RunningContainer(
                    id: $0.id ?? $0.configuration.id ?? "unknown",
                    imageReference: $0.configuration.image.reference,
                    digest: $0.configuration.image.descriptor?.digest,
                    network: $0.configuration.networks?.first?.network
                )
            }
    }

    /// OCI labels from a local image's config (e.g. `org.opencontainers.image.source`); empty if unavailable.
    static func imageLabels(_ reference: String) async -> [String: String] {
        struct Inspect: Decodable {
            struct Variant: Decodable {
                struct Config: Decodable {
                    struct Inner: Decodable { let Labels: [String: String]? }
                    let config: Inner?
                }
                let config: Config?
            }
            let variants: [Variant]?
        }
        guard let data = try? await run(["image", "inspect", reference]),
              let items = try? JSONDecoder().decode([Inspect].self, from: data) else { return [:] }
        return items.compactMap { $0.variants }.flatMap { $0 }
            .compactMap { $0.config?.config?.Labels }
            .first { !$0.isEmpty } ?? [:]
    }

    /// Downloads an image into the local store. Running containers are not touched.
    static func pull(_ reference: String) async throws {
        _ = try await run(["image", "pull", "--progress", "none", reference])
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        guard let url = locate() else { throw ContainerCLIError.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = url
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: outData)
                } else {
                    let text = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ContainerCLIError.failed(
                        text.isEmpty ? "`container` exited with status \(process.terminationStatus)" : text))
                }
            }
        }
    }
}

private struct RawContainer: Decodable {
    struct Configuration: Decodable {
        struct Image: Decodable {
            struct Descriptor: Decodable { let digest: String }
            let reference: String
            let descriptor: Descriptor?
        }
        struct Attachment: Decodable { let network: String }
        let id: String?
        let image: Image
        let networks: [Attachment]?
    }
    struct Status: Decodable { let state: String? }

    let id: String?
    let configuration: Configuration
    let status: Status?
}
