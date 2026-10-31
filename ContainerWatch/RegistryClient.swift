import Foundation

struct RegistryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal OCI distribution client: lists tags and resolves a tag's manifest digest.
/// Handles the anonymous Bearer-token handshake used by Docker Hub, ghcr.io and most public registries.
actor RegistryClient {
    private var tokens: [String: String] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func tags(for ref: ImageReference) async throws -> [String] {
        struct Page: Decodable { let tags: [String]? }
        let base = baseURL(ref)
        var next = URL(string: "/v2/\(ref.repository)/tags/list?n=1000", relativeTo: base)?.absoluteURL
        var all: [String] = []
        var pages = 0
        while let url = next, pages < 40 {
            let (data, response) = try await send(url, method: "GET", accept: nil, ref: ref)
            guard response.statusCode == 200 else { throw failure(response, "listing tags") }
            all += try JSONDecoder().decode(Page.self, from: data).tags ?? []
            next = nextLink(in: response, base: base)
            pages += 1
        }
        return all
    }

    func digest(for ref: ImageReference, tag: String) async throws -> String {
        let accept = [
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.v2+json",
        ].joined(separator: ", ")
        guard let url = URL(string: "/v2/\(ref.repository)/manifests/\(tag)", relativeTo: baseURL(ref))?.absoluteURL else {
            throw RegistryError(message: "Invalid image reference")
        }
        let (_, response) = try await send(url, method: "HEAD", accept: accept, ref: ref)
        guard response.statusCode == 200 else { throw failure(response, "resolving \(tag)") }
        guard let digest = response.value(forHTTPHeaderField: "Docker-Content-Digest") else {
            throw RegistryError(message: "Registry returned no digest for \(tag)")
        }
        return digest
    }

    // MARK: - Plumbing

    private func baseURL(_ ref: ImageReference) -> URL {
        let host = ref.registry == "docker.io" ? "registry-1.docker.io" : ref.registry
        let scheme = host.hasPrefix("localhost") ? "http" : "https"
        return URL(string: "\(scheme)://\(host)")!
    }

    private func failure(_ response: HTTPURLResponse, _ action: String) -> RegistryError {
        switch response.statusCode {
        case 401, 403: RegistryError(message: "Registry requires authentication (\(action))")
        case 404: RegistryError(message: "Not found while \(action)")
        case 429: RegistryError(message: "Rate limited by registry")
        default: RegistryError(message: "Registry returned HTTP \(response.statusCode) while \(action)")
        }
    }

    private func send(_ url: URL, method: String, accept: String?, ref: ImageReference) async throws -> (Data, HTTPURLResponse) {
        let key = "\(ref.registry)/\(ref.repository)"
        func request(_ token: String?) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = method
            if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return req
        }
        var (data, response) = try await session.data(for: request(tokens[key]))
        guard var http = response as? HTTPURLResponse else { throw RegistryError(message: "Invalid response") }
        if http.statusCode == 401,
           let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate"),
           let token = try await fetchToken(challenge: challenge, ref: ref) {
            tokens[key] = token
            (data, response) = try await session.data(for: request(token))
            guard let retried = response as? HTTPURLResponse else { throw RegistryError(message: "Invalid response") }
            http = retried
        }
        return (data, http)
    }

    private func fetchToken(challenge: String, ref: ImageReference) async throws -> String? {
        guard challenge.lowercased().hasPrefix("bearer") else { return nil }
        var params: [String: String] = [:]
        let regex = try NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
        for match in regex.matches(in: challenge, range: NSRange(challenge.startIndex..., in: challenge)) {
            if let k = Range(match.range(at: 1), in: challenge), let v = Range(match.range(at: 2), in: challenge) {
                params[String(challenge[k]).lowercased()] = String(challenge[v])
            }
        }
        guard let realm = params["realm"], var components = URLComponents(string: realm) else { return nil }
        var items = components.queryItems ?? []
        if let service = params["service"] { items.append(URLQueryItem(name: "service", value: service)) }
        items.append(URLQueryItem(name: "scope", value: params["scope"] ?? "repository:\(ref.repository):pull"))
        components.queryItems = items
        guard let url = components.url else { return nil }

        struct Token: Decodable { let token: String?; let access_token: String? }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let decoded = try JSONDecoder().decode(Token.self, from: data)
        return decoded.token ?? decoded.access_token
    }

    private func nextLink(in response: HTTPURLResponse, base: URL) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link"),
              link.contains("rel=\"next\""),
              let open = link.firstIndex(of: "<"), let close = link.firstIndex(of: ">"), open < close
        else { return nil }
        return URL(string: String(link[link.index(after: open)..<close]), relativeTo: base)?.absoluteURL
    }
}
