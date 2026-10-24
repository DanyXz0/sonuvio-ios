import Foundation

/// Dirección de Sonuvio que abre la app. Por defecto, la web publicada; se cambia desde
/// Ajustes → «Servidor de Sonuvio» dentro de la propia web (llama a SonuvioNative.changeAccess()).
enum ServerSettings {
    static let defaultAddress = URL(string: "https://sonuvio.vercel.app")!
    private static let key = "serverAddress"

    static var address: URL {
        get {
            if let saved = UserDefaults.standard.string(forKey: key), let url = normalized(saved) {
                return url
            }
            return defaultAddress
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: key)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Acepta «sonuvio.vercel.app», «https://…» o «http://192.168.1.20:4173». Se queda solo con el origen.
    static func normalized(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// La navegación dentro de este origen se queda en la app; el resto se abre en Safari.
    static func isSonuvio(_ url: URL) -> Bool {
        let home = address
        return url.scheme?.lowercased() == home.scheme
            && url.host?.lowercased() == home.host?.lowercased()
            && url.port == home.port
    }
}
