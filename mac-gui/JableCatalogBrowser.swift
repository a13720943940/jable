import SwiftUI
import WebKit

@MainActor
final class JableMediaURLRefresher: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var continuation: CheckedContinuation<String, Error>?
    private var webView: WKWebView?
    private var expectedPageURL = ""
    private var timeoutTask: Task<Void, Never>?

    func refreshMediaURL(from detailURL: String) async throws -> String {
        expectedPageURL = detailURL
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.userContentController.add(self, name: "jableCapture")
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Self.captureScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            webView.load(URLRequest(url: URL(string: detailURL)!))

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.finish(.failure(NSError(
                    domain: "JableMediaURLRefresher",
                    code: 408,
                    userInfo: [NSLocalizedDescriptionKey: "刷新最新 M3U8 超时"]
                )))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.querySelector('.plyr__control--overlaid')?.click(); document.querySelector('video')?.play?.();")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let mediaURL = body["media_url"] as? String,
              mediaURL.lowercased().contains(".m3u8") else { return }
        let pageURL = (body["page_url"] as? String) ?? ""
        guard pageURL.contains("/videos/") else { return }
        if !expectedPageURL.isEmpty, pageURL != expectedPageURL {
            return
        }
        finish(.success(mediaURL))
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "jableCapture")
        webView = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private static let captureScript = #"""
    (() => {
      if (window.__jableRefreshCaptureInstalled) return;
      window.__jableRefreshCaptureInstalled = true;
      const seen = new Set();
      const report = (candidate) => {
        const mediaURL = String(candidate || '');
        if (!/\.m3u8(?:$|[?#])/i.test(mediaURL) || seen.has(mediaURL)) return;
        seen.add(mediaURL);
        const heading = document.querySelector('h4, h1, .title, meta[property="og:title"]');
        const rawTitle = heading?.content || heading?.textContent || document.title || '';
        window.webkit?.messageHandlers?.jableCapture?.postMessage({
          media_url: mediaURL,
          title: rawTitle.replace(/\s*[|-]\s*Jable.*$/i, '').trim(),
          page_url: location.href
        });
      };
      const scan = () => {
        performance.getEntriesByType('resource').forEach(entry => report(entry.name));
        const video = document.querySelector('video');
        const source = video?.currentSrc || video?.src || document.querySelector('source')?.src;
        report(source);
        if (video && video.paused) {
          video.muted = true;
          video.play().catch(() => document.querySelector('.plyr__control--overlaid')?.click());
        } else {
          document.querySelector('.plyr__control--overlaid')?.click();
        }
      };
      try {
        new PerformanceObserver(list => list.getEntries().forEach(entry => report(entry.name)))
          .observe({type: 'resource', buffered: true});
      } catch (_) {}
      const nativeFetch = window.fetch;
      window.fetch = function(...args) {
        report(args[0]?.url || args[0]);
        return nativeFetch.apply(this, args).then(response => { report(response.url); return response; });
      };
      const nativeOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        report(url);
        return nativeOpen.call(this, method, url, ...rest);
      };
      setInterval(scan, 900);
      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
    })();
    """#
}

private struct JablePageCapture {
    let mediaURL: String
    let title: String
    let pageURL: String
}

struct JableCatalogBrowserSheet: View {
    @ObservedObject var viewModel: QueueDownloadViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var status = "在列表页点击影片后会后台抓取 M3U8 并立即入队"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("自动影片库", systemImage: "film.stack")
                    .font(.headline)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider()

            JableCatalogWebView(status: $status) { capture in
                viewModel.addCapturedJableTask(
                    mediaURL: capture.mediaURL,
                    title: capture.title,
                    pageURL: capture.pageURL
                )
                status = "已加入队列并开始执行，可继续留在当前页面选片"
            }
        }
        .frame(minWidth: 980, minHeight: 720)
    }
}

private struct JableCatalogWebView: NSViewRepresentable {
    @Binding var status: String
    let onCapture: (JablePageCapture) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status, onCapture: onCapture)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "jableCapture")
        configuration.userContentController.add(context.coordinator, name: "jableOpenDetail")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.captureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        context.coordinator.webView = webView
        webView.load(URLRequest(url: URL(string: "https://jable.tv/latest-updates/")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "jableCapture")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "jableOpenDetail")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        @Binding private var status: String
        private let onCapture: (JablePageCapture) -> Void
        private var deliveredPageURL = ""
        private var pendingDetailURL = ""
        weak var webView: WKWebView?
        private var backgroundWebView: WKWebView?

        init(status: Binding<String>, onCapture: @escaping (JablePageCapture) -> Void) {
            _status = status
            self.onCapture = onCapture
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            status = "正在加载页面…"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let isDetail = webView.url?.path.contains("/videos/") == true
            if webView === backgroundWebView {
                status = isDetail ? "后台详情页已打开，正在抓取 M3U8…" : "后台抓取页已准备好"
            } else {
                status = isDetail ? "正在播放并捕获影片连接…" : "请在列表页直接点击影片，后台会自动加入队列"
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            status = "页面加载失败：\(error.localizedDescription)"
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "jableOpenDetail" {
                guard let body = message.body as? [String: Any],
                      let detailURL = body["detail_url"] as? String,
                      detailURL.contains("/videos/") else { return }
                let requestedTitle = (body["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                openDetailInBackground(detailURL: detailURL, title: requestedTitle)
                return
            }

            guard let body = message.body as? [String: Any],
                  let mediaURL = body["media_url"] as? String,
                  mediaURL.lowercased().contains(".m3u8") else { return }
            let pageURL = (body["page_url"] as? String) ?? ""
            guard
                  pageURL.contains("/videos/"),
                  pageURL != deliveredPageURL else { return }

            deliveredPageURL = pageURL
            pendingDetailURL = ""
            status = "已捕获 M3U8，正在加入任务队列…"
            let capturedTitle = (body["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = capturedTitle.isEmpty ? "自动标题" : capturedTitle
            onCapture(JablePageCapture(mediaURL: mediaURL, title: title, pageURL: pageURL))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.status = "已加入队列并开始执行，可继续打开下一部影片"
            }
        }

        private func openDetailInBackground(detailURL: String, title: String) {
            guard pendingDetailURL != detailURL else { return }
            guard pendingDetailURL.isEmpty else {
                status = "上一部影片仍在后台抓取，请稍等片刻…"
                return
            }
            pendingDetailURL = detailURL
            deliveredPageURL = ""
            status = "已触发 \(title.isEmpty ? "影片" : title)，后台正在抓取 M3U8…"
            let hidden = backgroundWebView ?? makeBackgroundWebView()
            hidden.load(URLRequest(url: URL(string: detailURL)!))
        }

        private func makeBackgroundWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.userContentController.add(self, name: "jableCapture")
            configuration.userContentController.add(self, name: "jableOpenDetail")
            configuration.userContentController.addUserScript(WKUserScript(
                source: JableCatalogWebView.captureScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            let hidden = WKWebView(frame: .zero, configuration: configuration)
            hidden.navigationDelegate = self
            hidden.uiDelegate = self
            backgroundWebView = hidden
            return hidden
        }
    }

    private static let captureScript = #"""
    (() => {
      if (window.__jableNativeCaptureInstalled) return;
      window.__jableNativeCaptureInstalled = true;
      const seen = new Set();
      const report = (candidate) => {
        const mediaURL = String(candidate || '');
        if (!/\.m3u8(?:$|[?#])/i.test(mediaURL) || seen.has(mediaURL)) return;
        seen.add(mediaURL);
        const heading = document.querySelector('h4, h1, .title, meta[property="og:title"]');
        const rawTitle = heading?.content || heading?.textContent || document.title || '';
        window.webkit?.messageHandlers?.jableCapture?.postMessage({
          media_url: mediaURL,
          title: rawTitle.replace(/\s*[|-]\s*Jable.*$/i, '').trim(),
          page_url: location.href
        });
      };
      document.addEventListener('click', (event) => {
        const anchor = event.target.closest?.('a[href*="/videos/"]');
        if (!anchor) return;
        const href = anchor.href || '';
        if (!/\/videos\//.test(href)) return;
        if (/\/videos\//.test(location.pathname)) return;
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation?.();
        const titleNode = anchor.closest('.detail, .video-img-box, article, .row')?.querySelector('h6, h4, .title, a[href*="/videos/"]');
        const title = (titleNode?.textContent || anchor.textContent || '').replace(/\s+/g, ' ').trim();
        window.webkit?.messageHandlers?.jableOpenDetail?.postMessage({
          detail_url: href,
          title
        });
      }, true);
      const scan = () => {
        performance.getEntriesByType('resource').forEach(entry => report(entry.name));
        if (/\/videos\//.test(location.pathname)) {
          const video = document.querySelector('video');
          const source = video?.currentSrc || video?.src || document.querySelector('source')?.src;
          report(source);
          if (video && video.paused) {
            video.muted = true;
            video.play().catch(() => document.querySelector('.plyr__control--overlaid')?.click());
          }
        }
      };
      try {
        new PerformanceObserver(list => list.getEntries().forEach(entry => report(entry.name)))
          .observe({type: 'resource', buffered: true});
      } catch (_) {}
      const nativeFetch = window.fetch;
      window.fetch = function(...args) {
        report(args[0]?.url || args[0]);
        return nativeFetch.apply(this, args).then(response => { report(response.url); return response; });
      };
      const nativeOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url, ...rest) {
        report(url);
        return nativeOpen.call(this, method, url, ...rest);
      };
      setInterval(scan, 1200);
      document.addEventListener('DOMContentLoaded', scan);
    })();
    """#
}
