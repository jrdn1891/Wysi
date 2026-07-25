import WebKit

final class WysiSchemeHandler: NSObject, WKURLSchemeHandler {
    private let base: URL

    init(base: URL = Bundle.main.resourceURL!.appendingPathComponent("Editor")) {
        self.base = base
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "app"
        else { return urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)) }
        let file = base.appendingPathComponent(String(url.path.dropFirst()))
        guard let data = try? Data(contentsOf: file)
        else { return urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)) }
        let mime = ["html": "text/html", "js": "text/javascript", "css": "text/css"][file.pathExtension] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "\(mime); charset=utf-8"])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
