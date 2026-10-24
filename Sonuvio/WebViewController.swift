import UIKit
import WebKit

/// Sonuvio a pantalla completa. La web se ocupa de todo (cuentas, biblioteca, Connect, código de acceso);
/// la app añade audio en segundo plano, el puente nativo y abre fuera los enlaces a otros sitios.
final class WebViewController: UIViewController {
    private var webView: WKWebView!
    private let bridge = NativeBridge()
    private var statusBarStyle: UIStatusBarStyle = .lightContent
    private var showingError = false

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // La siguiente canción empieza sola, también con la pantalla bloqueada.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.applicationNameForUserAgent = "SonuvioApp/" + NativeBridge.appVersion
        // Almacén persistente: el código de acceso y la sesión se recuerdan entre aperturas.
        configuration.websiteDataStore = .default()
        bridge.install(in: configuration.userContentController)

        let background = UIColor(named: "LaunchBackground") ?? .black
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        // La web ya respeta la muesca y la barra de inicio con env(safe-area-inset-*).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        self.webView = webView
        view = webView

        bridge.webView = webView
        bridge.presenter = self
        bridge.onTheme = { [weak self] color in self?.apply(background: color) }
        bridge.onChangeServer = { [weak self] in self?.askForServer() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        load(ServerSettings.address)
    }

    private func load(_ url: URL) {
        showingError = false
        webView.load(URLRequest(url: url))
    }

    private func apply(background color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let dark = 0.299 * red + 0.587 * green + 0.114 * blue < 0.5
        statusBarStyle = dark ? .lightContent : .darkContent
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        view.window?.backgroundColor = color
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - Servidor

    func askForServer() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Servidor de Sonuvio",
                                      message: "Dirección que abre la app. Normalmente no hace falta cambiarla.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = ServerSettings.address.absoluteString
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel))
        alert.addAction(UIAlertAction(title: "Usar la de siempre", style: .default) { [weak self] _ in
            ServerSettings.reset()
            self?.load(ServerSettings.address)
        })
        alert.addAction(UIAlertAction(title: "Guardar", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let url = ServerSettings.normalized(text) else {
                self?.showMessage(title: "Dirección no válida", message: "Escribe algo como https://sonuvio.vercel.app")
                return
            }
            ServerSettings.address = url
            self?.load(url)
        })
        present(alert, animated: true)
    }

    private func showConnectionError(_ error: Error) {
        guard !showingError, presentedViewController == nil else { return }
        showingError = true
        let host = ServerSettings.address.host ?? ServerSettings.address.absoluteString
        let alert = UIAlertController(title: "No se puede abrir Sonuvio",
                                      message: "\(error.localizedDescription)\n\nServidor: \(host)",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cambiar servidor", style: .default) { [weak self] _ in
            self?.showingError = false
            self?.askForServer()
        })
        alert.addAction(UIAlertAction(title: "Reintentar", style: .cancel) { [weak self] _ in
            self?.load(ServerSettings.address)
        })
        present(alert, animated: true)
    }

    private func showMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Navegación

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        // Solo se decide la página principal: marcos internos, about:, blob: y data: siguen dentro.
        if ["about", "blob", "data"].contains(scheme)
            || navigationAction.targetFrame?.isMainFrame == false
            || ServerSettings.isSonuvio(url) {
            decisionHandler(.allow)
            return
        }
        // YouTube Music, Audius, correo… se abren en su app o en Safari.
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func handle(_ error: Error) {
        let nsError = error as NSError
        // Navegaciones canceladas a propósito (enlaces abiertos fuera, recargas) no son fallos.
        if nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        showConnectionError(error)
    }
}

// MARK: - Ventanas y diálogos de la web

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Enlaces con target="_blank": fuera de la app.
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard presentedViewController == nil else {
            completionHandler()
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard presentedViewController == nil else {
            completionHandler(nil)
            return
        }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}
