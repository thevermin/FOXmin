import Foundation

/// Busca la última versión publicada en GitHub Releases.
final class UpdateChecker {
    struct Release {
        let version: String
        let url: URL
    }

    static let repo = "thevermin/FOXmin"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Versión más nueva encontrada en la última búsqueda (nil si estás al día).
    private(set) var available: Release?
    private var timer: Timer?

    /// Busca al abrir la app y después una vez por día, sin molestar.
    func startAutomaticChecks(onUpdate: @escaping () -> Void) {
        check { _ in onUpdate() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check { _ in onUpdate() }
        }
    }

    /// `completion` recibe la versión nueva, nil si estás al día, o un error si no se pudo consultar.
    func check(completion: @escaping (_ result: Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<Release?, Error>
            if let error {
                result = .failure(error)
            } else if (response as? HTTPURLResponse)?.statusCode == 404 {
                result = .success(nil) // todavía no hay ninguna versión publicada
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String {
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
                let newer = Self.isNewer(version, than: Self.currentVersion)
                result = .success(newer ? Release(version: version, url: page) : nil)
            } else {
                result = .failure(URLError(.badServerResponse))
            }

            DispatchQueue.main.async {
                if case .success(let release) = result { self?.available = release }
                completion(result)
            }
        }.resume()
    }

    /// Compara versiones tipo "0.2.1" número por número.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
