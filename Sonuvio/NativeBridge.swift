import UIKit
import WebKit

/// window.SonuvioNative dentro de la app de iPhone: la misma interfaz que en Android y Windows
/// (sonuvio-web/src/native-app.ts). La web la usa para la pantalla de bloqueo, exportar la biblioteca
/// y cambiar la dirección del servidor.
final class NativeBridge: NSObject, WKScriptMessageHandler {
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    weak var webView: WKWebView?
    weak var presenter: UIViewController?
    var onTheme: ((UIColor) -> Void)?
    var onChangeServer: (() -> Void)?
    private let nowPlaying = NowPlaying()

    override init() {
        super.init()
        nowPlaying.send = { [weak self] action, position in self?.send(action: action, position: position) }
    }

    func install(in controller: WKUserContentController) {
        controller.add(WeakMessageHandler(self), name: "sonuvio")
        let source = Self.script.replacingOccurrences(of: "__VERSION__", with: Self.appVersion)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let method = body["method"] as? String else { return }
        switch method {
        case "ready":
            // Si WebKit ofrece navigator.mediaSession, la web ya publica la canción y atiende los botones
            // de la pantalla de bloqueo; la app solo lo hace cuando falta, para no aplicar cada pulsación dos veces.
            if (body["mediaSession"] as? Bool) != true { nowPlaying.enable() }
        case "updateMedia":
            if let json = body["json"] as? String { nowPlaying.update(json: json) }
        case "clearMedia":
            nowPlaying.clear()
        case "saveFile":
            if let name = body["name"] as? String, let base64 = body["base64"] as? String { save(name: name, base64: base64) }
        case "changeAccess":
            onChangeServer?()
        case "theme":
            if let css = body["background"] as? String, let color = Self.color(fromCSS: css) { onTheme?(color) }
        default:
            break
        }
    }

    /// Botones de la pantalla de bloqueo → reproductor de la web (src/native-bridge.ts escucha «sonuvio-native»).
    func send(action: String, position: Int?) {
        var detail = "{\"action\":\"\(action)\""
        if let position = position { detail += ",\"position\":\(position)" }
        detail += "}"
        webView?.evaluateJavaScript("window.dispatchEvent(new CustomEvent('sonuvio-native',{detail:\(detail)}))",
                                    completionHandler: nil)
    }

    /// Exportar la biblioteca: la hoja de compartir de iOS permite guardarla en Archivos o enviarla.
    private func save(name: String, base64: String) {
        guard let data = Data(base64Encoded: base64), let presenter = presenter else { return }
        let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName.isEmpty ? "sonuvio.json" : safeName)
        do { try data.write(to: url, options: .atomic) } catch { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        if presenter.presentedViewController == nil { presenter.present(sheet, animated: true) }
    }

    /// «rgb(5, 5, 5)» o «rgba(…)» → color; nil si es transparente o no se entiende.
    static func color(fromCSS css: String) -> UIColor? {
        let numbers = css.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).compactMap { Double($0) }
        guard numbers.count >= 3 else { return nil }
        if numbers.count >= 4 && numbers[3] == 0 { return nil }
        return UIColor(red: CGFloat(numbers[0] / 255), green: CGFloat(numbers[1] / 255), blue: CGFloat(numbers[2] / 255), alpha: 1)
    }

    // Se inyecta antes que la web: native-app.ts lee window.SonuvioNative al arrancar.
    private static let script = #"""
    (function () {
      if (window.SonuvioNative) return;
      var post = function (message) {
        try { window.webkit.messageHandlers.sonuvio.postMessage(message); } catch (error) {}
      };
      window.SonuvioNative = {
        version: function () { return "__VERSION__"; },
        platform: function () { return "ios"; },
        updateMedia: function (json) { post({ method: "updateMedia", json: String(json) }); },
        clearMedia: function () { post({ method: "clearMedia" }); },
        saveFile: function (name, mime, base64) {
          post({ method: "saveFile", name: String(name), mime: String(mime), base64: String(base64) });
          return true;
        },
        changeAccess: function () { post({ method: "changeAccess" }); }
      };
      post({ method: "ready", mediaSession: "mediaSession" in navigator });
      // Color de fondo de la web (tema oscuro o claro) para la barra de estado de iOS.
      var last = "";
      var pick = function (element) {
        var color = element && getComputedStyle(element).backgroundColor;
        return color && color !== "rgba(0, 0, 0, 0)" && color !== "transparent" ? color : null;
      };
      var report = function () {
        var color = pick(document.body) || pick(document.documentElement);
        if (color && color !== last) { last = color; post({ method: "theme", background: color }); }
      };
      var watch = function () {
        report();
        new MutationObserver(report).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "style", "class"] });
        window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", report);
      };
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch); else watch();
    })();
    """#
}

/// WKUserContentController retiene a quien recibe los mensajes: este intermediario evita un ciclo de memoria.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
