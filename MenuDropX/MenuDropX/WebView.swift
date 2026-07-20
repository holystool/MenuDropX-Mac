import SwiftUI
import WebKit

struct WebView: NSViewRepresentable {
    static var activeWebViews: [WeakWKWebView] = []
    
    @ObservedObject var viewModel: WebViewModel
    
    // 移动端 User-Agent 常量
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    
    // 桌面端 User-Agent 常量
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    
    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        
        // 编译并注入轻量级网页内容阻断规则 (防广告/防追踪拦截)，大幅节省 TCP 连接和带宽，极速提升加载速度
        let blockerRules = """
        [
            {
                "trigger": {
                    "url-filter": ".*(analytics|doubleclick|google-analytics|pagead|adnxs|adsystem|adsense|adservice|facebook.*sdk|fbcdn|pixel|collect|track).*$"
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*(hm\\\\.baidu\\\\.com|tongji|cnzz|growingio|stat).*$"
                },
                "action": {
                    "type": "block"
                }
            }
        ]
        """
        if let store = WKContentRuleListStore.default() {
            store.compileContentRuleList(
                forIdentifier: "MenuDropXBlocker",
                encodedContentRuleList: blockerRules
            ) { ruleList, error in
                if let ruleList = ruleList, error == nil {
                    DispatchQueue.main.async {
                        configuration.userContentController.add(ruleList)
                    }
                }
            }
        }
        
        // 配置注入式 JS
        let userContentController = WKUserContentController()
        
        // 1. 去除滚动条脚本 (CSS)
        let hideScrollbarCSS = """
        var style = document.createElement('style');
        style.innerHTML = '::-webkit-scrollbar { display: none !important; }';
        document.head.appendChild(style);
        """
        let hideScrollbarScript = WKUserScript(source: hideScrollbarCSS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContentController.addUserScript(hideScrollbarScript)
        
        // 2. 无限滚动自动触发补丁 (JS)
        let infiniteScrollJS = """
        document.addEventListener('scroll', function(e) {
            var target = e.target;
            if (target === document || target === document.body || target === document.documentElement) {
                var remaining = document.documentElement.scrollHeight - window.innerHeight - window.scrollY;
                if (remaining < 300) {
                    triggerLoadMore();
                }
            } else if (target && target.scrollHeight > target.clientHeight) {
                var remaining = target.scrollHeight - target.clientHeight - target.scrollTop;
                if (remaining < 300) {
                    triggerLoadMore(target);
                }
            }
        }, true);

        function triggerLoadMore(element) {
            // 抛出标准 scroll 事件以激活懒加载监听器
            var ev = new Event('scroll', { bubbles: true, cancelable: true });
            (element || window).dispatchEvent(ev);
            
            // 仿真移动端 TouchMove 事件
            try {
                if (typeof Touch !== 'undefined') {
                    var targetEl = element || document.body;
                    var rect = targetEl.getBoundingClientRect();
                    var clientX = rect.left + rect.width / 2;
                    var clientY = rect.top + rect.height / 2;
                    
                    var touch = new Touch({
                        identifier: Date.now(),
                        target: targetEl,
                        clientX: clientX,
                        clientY: clientY,
                        screenX: clientX,
                        screenY: clientY,
                        pageX: clientX,
                        pageY: clientY
                    });
                    
                    var touchEvent = new TouchEvent('touchmove', {
                        bubbles: true,
                        cancelable: true,
                        touches: [touch],
                        targetTouches: [touch],
                        changedTouches: [touch]
                    });
                }
            } catch(e) {}
            
            // 监听右键菜单触发，获取选中文本实时传回 Swift，配合 willOpenMenu 原生右键菜单展示翻译
            document.addEventListener('contextmenu', function() {
                try {
                    var selected = window.getSelection().toString();
                    window.webkit.messageHandlers.menuDropXTranslate.postMessage({
                        type: 'selection',
                        text: selected || ''
                    });
                } catch(e) {}
            });
        }
        """
        let infiniteScrollScript = WKUserScript(source: infiniteScrollJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        userContentController.addUserScript(infiniteScrollScript)
        
        userContentController.add(context.coordinator, name: "menuDropXTranslate")
        configuration.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = viewModel.isDesktopUA ? Self.desktopUserAgent : Self.mobileUserAgent
        
        // 绑定命令执行器，避开 SwiftUI updateNSView 延迟和调用竞态，实现即时瞬间响应
        viewModel.loadURLExecutor = { [weak webView] urlStr in
            guard let webView = webView else { return }
            
            // 谷歌网页翻译（包含 translate.google.com 或 translate.goog）被请求时，
            // 恢复系统默认原生 Safari UA，这能完美规避谷歌对模拟 Chrome 等第三方 UA 指纹的自动化脚本审计风控
            let isGoogleTranslate = urlStr.contains("translate.google.com") || urlStr.contains("translate.goog")
            webView.customUserAgent = isGoogleTranslate ? nil : (viewModel.isDesktopUA ? Self.desktopUserAgent : Self.mobileUserAgent)
            
            if urlStr == "menudropx://home" {
                webView.loadHTMLString(Self.navigationHTML, baseURL: URL(string: "https://menudropx.local"))
            } else if let url = URL(string: urlStr) {
                webView.load(URLRequest(url: url))
            }
        }
        viewModel.loadHomeExecutor = { [weak webView] in
            webView?.loadHTMLString(Self.navigationHTML, baseURL: URL(string: "https://menudropx.local"))
        }
        viewModel.goBackExecutor = { [weak webView] in
            if webView?.canGoBack == true {
                webView?.goBack()
            }
        }
        viewModel.goForwardExecutor = { [weak webView] in
            if webView?.canGoForward == true {
                webView?.goForward()
            }
        }
        viewModel.reloadExecutor = { [weak webView] in
            webView?.reload()
        }
        viewModel.evaluateJSExecutor = { [weak webView] jsCode in
            webView?.evaluateJavaScript(jsCode, completionHandler: nil)
        }
        
        // 监听 URL 与前进后退状态变化（KVO 可完美拦截 SPA 应用的 HTML5 History API 路由修改，如 pushState）
        context.coordinator.urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak viewModel] webView, _ in
            DispatchQueue.main.async {
                guard let viewModel = viewModel else { return }
                let isHomePage = webView.url?.host == "menudropx.local"
                if isHomePage {
                    viewModel.urlInput = ""
                } else if let url = webView.url, let scheme = url.scheme, scheme.hasPrefix("http") {
                    viewModel.urlInput = url.absoluteString
                }
            }
        }
        
        context.coordinator.backObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak viewModel] webView, _ in
            DispatchQueue.main.async {
                viewModel?.canGoBack = webView.canGoBack
            }
        }
        
        context.coordinator.forwardObservation = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak viewModel] webView, _ in
            DispatchQueue.main.async {
                viewModel?.canGoForward = webView.canGoForward
            }
        }
        
        // 追踪活跃的真实 WKWebView 实例，以在 UserDefaults 或配置改变时直接跨窗口广播同步
        WebView.activeWebViews.append(WeakWKWebView(webView, viewModel: viewModel))
        WebView.activeWebViews.removeAll { $0.webView == nil }
        
        // 初始加载：优先读取 viewModel.urlInput（恢复配置时已预置真实 URL），否则加载默认首页
        let initialURLString = viewModel.urlInput
        if initialURLString.isEmpty || initialURLString == "menudropx://home" {
            webView.loadHTMLString(Self.navigationHTML, baseURL: URL(string: "https://menudropx.local"))
        } else if let url = URL(string: initialURLString) {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(Self.navigationHTML, baseURL: URL(string: "https://menudropx.local"))
        }
        
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 只有当 isDesktopUA 状态真正发生改变时（比如用户在底栏点击了“切换浏览器标识”），
        // 我们才更新 customUserAgent 并执行 nsView.reload()，彻底消除在加载/跳转过程中由于 URL 变化触发重载的冲突
        if context.coordinator.lastIsDesktopUA != viewModel.isDesktopUA {
            let targetUA = viewModel.isDesktopUA ? Self.desktopUserAgent : Self.mobileUserAgent
            nsView.customUserAgent = targetUA
            
            // 如果不是首次渲染，则重载以应用新的 UA 网页
            if context.coordinator.lastIsDesktopUA != nil {
                nsView.reload()
            }
            context.coordinator.lastIsDesktopUA = viewModel.isDesktopUA
        }
        
        switch viewModel.action {
        case .none:
            break
        case .goBack:
            if nsView.canGoBack {
                nsView.goBack()
            }
        case .goForward:
            if nsView.canGoForward {
                nsView.goForward()
            }
        case .reload:
            nsView.reload()
        case .load(let urlString):
            if urlString == "menudropx://home" {
                nsView.loadHTMLString(Self.navigationHTML, baseURL: URL(string: "https://menudropx.local"))
            } else if let url = URL(string: urlString) {
                let request = URLRequest(url: url)
                nsView.load(request)
            }
        case .loadHome:
            nsView.loadHTMLString(Self.navigationHTML, baseURL: URL(string: "https://menudropx.local"))
        }
        
        if viewModel.action != .none {
            DispatchQueue.main.async {
                viewModel.action = .none
            }
        }
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var viewModel: WebViewModel
        var isFirstUpdate = true
        var lastIsDesktopUA: Bool? = nil
        var lastSelectedText: String = ""
        
        // 观察者生命周期持有者，防止出作用域被自动销毁
        var urlObservation: NSKeyValueObservation?
        var backObservation: NSKeyValueObservation?
        var forwardObservation: NSKeyValueObservation?
        
        init(_ viewModel: WebViewModel) {
            self.viewModel = viewModel
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.viewModel.isLoading = true
                self.syncNavigationState(webView)
            }
        }
        
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.syncNavigationState(webView)
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.viewModel.isLoading = false
                self.syncNavigationState(webView)
                
                // 页面完全加载完成后，才去尝试下载网页图标
                if let url = webView.url, let host = url.host, url.host != "menudropx.local" {
                    self.fetchFavicon(for: host) { [weak self] colorImg, templateImg in
                        DispatchQueue.main.async {
                            self?.viewModel.currentFaviconColor = colorImg
                            self?.viewModel.currentFavicon = templateImg
                        }
                    }
                }
            }
        }
        
        /// 统一的实时同步方法
        private func syncNavigationState(_ webView: WKWebView) {
            let isHomePage = webView.url?.host == "menudropx.local"
            
            if isHomePage {
                // 本地导航首页：清空 URL 栏和图标，并注入最新的预设配置数据
                self.viewModel.urlInput = ""
                self.viewModel.currentFavicon = nil
                self.viewModel.currentFaviconColor = nil
                WebView.injectPresetsDataStatic(to: webView)
            }
            self.viewModel.isPageTranslated = false
        }
        
        // 核心拦截跳转：监听 menudropx:// 自定义加载/清空配置协议并触发 Swift 对应操作
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme,
               scheme == "menudropx" {
                
                // 拦截加载配置指令
                if url.host == "loadconfig",
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = components.queryItems,
                   let idStr = queryItems.first(where: { $0.name == "id" })?.value,
                   let id = Int(idStr) {
                    
                    DispatchQueue.main.async {
                        if let appDelegate = AppDelegate.shared {
                            if let instance = appDelegate.instances.first(where: { $0.viewModel === self.viewModel }) {
                                appDelegate.loadPresetConfig(id: id, fromInstance: instance)
                            }
                        }
                    }
                }
                
                // 拦截删除配置指令
                if url.host == "deleteconfig",
                   let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = components.queryItems,
                   let idStr = queryItems.first(where: { $0.name == "id" })?.value,
                   let id = Int(idStr) {
                    
                    DispatchQueue.main.async {
                        if let appDelegate = AppDelegate.shared {
                            appDelegate.confirmAndDeletePresetConfig(id: id)
                        }
                    }
                }
                
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.viewModel.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.viewModel.isLoading = false
            }
        }
        
        // MARK: - WKScriptMessageHandler & 本地翻译多通道代理核心处理逻辑
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "menuDropXTranslate",
               let body = message.body as? [String: Any] {
                
                // 类型一：右键选中文本的实时同步暂存
                if let type = body["type"] as? String, type == "selection" {
                    if let text = body["text"] as? String {
                        self.lastSelectedText = text
                    }
                    return
                }
                
                // 类型二：增量翻译（用于 MutationObserver 滚动加载新内容）
                if let type = body["type"] as? String, type == "incremental",
                   let taskId = body["taskId"] as? String,
                   let texts = body["texts"] as? [String] {
                    translateTexts(texts, to: "zh-CN") { [weak self] translatedTexts in
                        self?.applyIncrementalTranslations(translatedTexts, taskId: taskId)
                    }
                    return
                }
                
                // 类型三：翻译整页的正文（首屏翻译）
                if let type = body["type"] as? String, type == "full-page",
                   let texts = body["texts"] as? [String] {
                    DispatchQueue.main.async {
                        self.viewModel.isTranslating = true
                    }
                    translateTexts(texts, to: "zh-CN") { [weak self] translatedTexts in
                        self?.applyTranslationsToPage(translatedTexts)
                    }
                    return
                }
                
                // 类型四：网页翻译状态回传同步
                if let type = body["type"] as? String, type == "status" {
                    if let isTrans = body["isTranslated"] as? Bool {
                        DispatchQueue.main.async {
                            self.viewModel.isPageTranslated = isTrans
                        }
                    }
                    return
                }
            }
        }
        /// 翻译大文本数组的核心分片 (Chunk) + 并发受限 (Max Concurrent: 3)
        private func translateTexts(_ texts: [String], to lang: String, completion: @escaping ([String]) -> Void) {
            guard !texts.isEmpty else {
                completion([])
                return
            }
            
            let filteredTexts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            
            // 分片打包，每包长度不超过 1500 字符（URL 长度限制考虑）
            var chunks: [[String]] = []
            var currentChunk: [String] = []
            var currentLength = 0
            
            for text in filteredTexts {
                let len = text.count
                if currentLength + len > 1500 && !currentChunk.isEmpty {
                    chunks.append(currentChunk)
                    currentChunk = []
                    currentLength = 0
                }
                currentChunk.append(text)
                currentLength += len
            }
            if !currentChunk.isEmpty {
                chunks.append(currentChunk)
            }
            
            let totalChunks = chunks.count
            var results: [Int: [String]] = [:]
            
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 3
            
            let mainFinishedGroup = DispatchGroup()
            
            for (index, chunk) in chunks.enumerated() {
                mainFinishedGroup.enter()
                
                queue.addOperation {
                    let innerGroup = DispatchGroup()
                    innerGroup.enter()
                    
                    var tempResult: [String]? = nil
                    
                    // 通道一：请求 clients5.google.com
                    self.requestGoogleTranslation(chunk, domain: "clients5.google.com", to: lang) { translatedTexts in
                        if let translatedTexts = translatedTexts {
                            tempResult = translatedTexts
                            innerGroup.leave()
                            return
                        }
                        
                        // 通道一失败，降级切换至通道二：translate.googleapis.com
                        self.requestGoogleTranslation(chunk, domain: "translate.googleapis.com", to: lang) { backupTranslated in
                            if let backupTranslated = backupTranslated {
                                tempResult = backupTranslated
                            }
                            innerGroup.leave()
                        }
                    }
                    
                    innerGroup.wait()
                    results[index] = tempResult ?? chunk
                    mainFinishedGroup.leave()
                }
            }
            
            mainFinishedGroup.notify(queue: .main) {
                var finalResult: [String] = []
                for i in 0..<totalChunks {
                    if let res = results[i] {
                        finalResult.append(contentsOf: res)
                    }
                }
                completion(finalResult)
            }
        }
        
        /// 请求谷歌高信用特许 API 接口，利用多 q 参数直接映射，完全避免正则截断风险
        private func requestGoogleTranslation(_ texts: [String], domain: String, to lang: String, completion: @escaping ([String]?) -> Void) {
            var queryItems = [
                URLQueryItem(name: "client", value: "dict-chrome-ex"),
                URLQueryItem(name: "sl", value: "auto"),
                URLQueryItem(name: "tl", value: lang)
            ]
            for text in texts {
                queryItems.append(URLQueryItem(name: "q", value: text))
            }
            
            var components = URLComponents()
            components.scheme = "https"
            components.host = domain
            components.path = "/translate_a/t"
            components.queryItems = queryItems
            
            guard let url = components.url else {
                completion(nil)
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8.0
            
            let randomOS = "10_15_\(Int.random(in: 4...7))"
            let randomSafari = "605.1.\(Int.random(in: 12...15))"
            let randomUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X \(randomOS)) AppleWebKit/\(randomSafari) (KHTML, like Gecko) Version/18.0 Safari/\(randomSafari)"
            request.setValue(randomUA, forHTTPHeaderField: "User-Agent")
            
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [[Any]] {
                    
                    let translatedTexts = json.compactMap { $0.first as? String }
                    // 确保返回的数组长度与请求的分片长度一致
                    if translatedTexts.count == texts.count {
                        completion(translatedTexts)
                        return
                    }
                }
                completion(nil)
            }.resume()
        }
        
        /// 将整页（首屏）翻译好的内容经 Base64 安全通道回填至网页 DOM 树中
        private func applyTranslationsToPage(_ translatedTexts: [String]) {
            let base64Texts = translatedTexts.map { $0.data(using: .utf8)?.base64EncodedString() ?? "" }
            let jsArray = "[" + base64Texts.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            
            let jsCode = """
            (function() {
                var base64s = \(jsArray);
                var activeItems = window.menuDropXActiveItems;
                if (!activeItems || activeItems.length === 0 || base64s.length !== activeItems.length) return;
                
                function base64DecodeUTF8(base64) {
                    var binString = window.atob(base64);
                    var bytes = new Uint8Array(binString.length);
                    for (var i = 0; i < binString.length; i++) {
                        bytes[i] = binString.charCodeAt(i);
                    }
                    return new TextDecoder('utf-8').decode(bytes);
                }
                
                for (var i = 0; i < activeItems.length; i++) {
                    try {
                        var decoded = base64DecodeUTF8(base64s[i]);
                        var item = activeItems[i];
                        if (item.type === 'text') {
                            // 采用对照翻译模式，在原文后面换行追加中文，并补齐原文末尾的换行/空格以隔离下一段
                            var trailing = "";
                            var orig = item.el.menuDropXOriginalText || "";
                            var match = orig.match(/\\s+$/);
                            if (match) { trailing = match[0]; }
                            item.el.nodeValue = orig + "\\n\\n" + decoded + trailing;
                        } else if (item.type === 'container') {
                            var transDiv = document.createElement('div');
                            transDiv.className = 'menudropx-translated-text';
                            transDiv.style.color = '#888888';
                            transDiv.style.fontSize = '0.95em';
                            transDiv.style.marginTop = '6px';
                            transDiv.style.lineHeight = '1.4';
                            transDiv.innerText = decoded;
                            item.el.appendChild(transDiv);
                        }
                    } catch(e) {
                        console.error("整页回填DOM出错:", e);
                    }
                }
                window.menuDropXActiveItems = null;
            })();
            """
            
            DispatchQueue.main.async {
                self.viewModel.evaluateJS(jsCode)
                self.viewModel.isTranslating = false
            }
        }
        
        /// 将增量翻译好的内容通过 taskId 原路安全回填到页面的动态 DOM 树中
        private func applyIncrementalTranslations(_ translatedTexts: [String], taskId: String) {
            let base64Texts = translatedTexts.map { $0.data(using: .utf8)?.base64EncodedString() ?? "" }
            let jsArray = "[" + base64Texts.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            
            let jsCode = """
            (function() {
                var base64s = \(jsArray);
                var queue = window.menuDropXPendingQueue;
                if (!queue || queue.length === 0) return;
                
                function base64DecodeUTF8(base64) {
                    var binString = window.atob(base64);
                    var bytes = new Uint8Array(binString.length);
                    for (var i = 0; i < binString.length; i++) {
                        bytes[i] = binString.charCodeAt(i);
                    }
                    return new TextDecoder('utf-8').decode(bytes);
                }
                
                var taskIndex = -1;
                for (var i = 0; i < queue.length; i++) {
                    if (queue[i].id === "\(taskId)") {
                        taskIndex = i;
                        break;
                    }
                }
                if (taskIndex === -1) return;
                
                var activeItems = queue[taskIndex].items;
                if (!activeItems || activeItems.length === 0 || base64s.length !== activeItems.length) {
                    queue.splice(taskIndex, 1);
                    return;
                }
                
                for (var i = 0; i < activeItems.length; i++) {
                    try {
                        var decoded = base64DecodeUTF8(base64s[i]);
                        var item = activeItems[i];
                        if (item.type === 'text') {
                            // 采用对照翻译模式，在原文后面换行追加中文，并补齐原文末尾的换行/空格以隔离下一段
                            var trailing = "";
                            var orig = item.el.menuDropXOriginalText || "";
                            var match = orig.match(/\\s+$/);
                            if (match) { trailing = match[0]; }
                            item.el.nodeValue = orig + "\\n\\n" + decoded + trailing;
                        } else if (item.type === 'container') {
                            var transDiv = document.createElement('div');
                            transDiv.className = 'menudropx-translated-text';
                            transDiv.style.color = '#888888';
                            transDiv.style.fontSize = '0.95em';
                            transDiv.style.marginTop = '6px';
                            transDiv.style.lineHeight = '1.4';
                            transDiv.innerText = decoded;
                            item.el.appendChild(transDiv);
                        }
                    } catch(e) {
                        console.error("增量回填DOM出错:", e);
                    }
                }
                queue.splice(taskIndex, 1);
            })();
            """
            
            DispatchQueue.main.async {
                self.viewModel.evaluateJS(jsCode)
            }
        }
        
        // MARK: - WKUIDelegate 自定义右键菜单翻译
        
        func webView(_ webView: WKWebView, willOpenMenu menu: NSMenu, with event: NSEvent) {
            let selected = lastSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty {
                menu.insertItem(NSMenuItem.separator(), at: 0)
                
                let translateItem = NSMenuItem(title: "翻译所选内容", action: #selector(self.menuTranslateSelectedText(_:)), keyEquivalent: "")
                translateItem.target = self
                translateItem.representedObject = selected
                menu.insertItem(translateItem, at: 0)
            }
        }
        
        @objc private func menuTranslateSelectedText(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            
            DispatchQueue.main.async {
                self.viewModel.isTranslating = true
            }
            
            // 调用我们写好的多通道网络翻译
            translateTexts([text], to: "zh-CN") { [weak self] results in
                DispatchQueue.main.async {
                    self?.viewModel.isTranslating = false
                    if let translated = results.first, !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 使用标准的原生 NSAlert 展示翻译结果
                        let alert = NSAlert()
                        alert.messageText = "所选文本翻译结果"
                        alert.informativeText = translated
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "确定")
                        
                        // 尝试附加到当前活动的主窗口上，使其以 Sheet 形式优雅滑出
                        if let window = NSApp.keyWindow {
                            alert.beginSheetModal(for: window, completionHandler: nil)
                        } else {
                            alert.runModal()
                        }
                    }
                }
            }
        }
        
        // 声明静态内存缓存，使所有的 WebView 实例和重新打开时可以共享已处理的图标
        static var iconMemoryCache: [String: NSImage] = [:]
        
        /// 异步下载 Favicon，仅使用内存缓存，下载后直接设置尺寸使用，不做任何像素渲染处理
        private func fetchFavicon(for host: String, completion: @escaping (NSImage?, NSImage?) -> Void) {
            // 1. 尝试从内存缓存中读取
            let cacheKey = host
            if let cached = Self.iconMemoryCache[cacheKey] {
                completion(cached, cached)
                return
            }
            
            // 2. 无缓存，下载
            let directURL = "https://\(host)/favicon.ico"
            let fallbackAPI = "https://api.iowen.cn/favicon/\(host).png"
            
            tryDownload(urls: [directURL, fallbackAPI], index: 0) { rawImage in
                guard let rawImage = rawImage else {
                    completion(nil, nil)
                    return
                }
                
                // 直接设置为 16x16，不做任何像素渲染
                rawImage.size = NSSize(width: 16, height: 16)
                rawImage.isTemplate = false
                
                Self.iconMemoryCache[cacheKey] = rawImage
                completion(rawImage, rawImage)
            }
        }
        
        private func tryDownload(urls: [String], index: Int, completion: @escaping (NSImage?) -> Void) {
            guard index < urls.count else {
                completion(nil)
                return
            }
            guard let url = URL(string: urls[index]) else {
                tryDownload(urls: urls, index: index + 1, completion: completion)
                return
            }
            
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data, let image = NSImage(data: data), image.size.width > 0 {
                    // 保留原始分辨率，供 processFaviconDual 在高分辨率上做精确像素分析
                    completion(image)
                } else {
                    self.tryDownload(urls: urls, index: index + 1, completion: completion)
                }
            }.resume()
        }
    }
}

// MARK: - 内置高质感可编辑 12 宫格毛玻璃常用导航页 HTML
extension WebView {
    static let navigationHTML = """
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <title>MenuDropX</title>
        <style>
            :root {
                --bg-gradient: linear-gradient(135deg, #181824 0%, #0a0a0f 100%);
                --card-bg: rgba(255, 255, 255, 0.05);
                --card-border: rgba(255, 255, 255, 0.1);
                --text-color: #ffffff;
                --text-secondary: rgba(255, 255, 255, 0.6);
                --modal-bg: rgba(30, 30, 45, 0.85);
            }
            @media (prefers-color-scheme: light) {
                :root {
                    --bg-gradient: linear-gradient(135deg, #e4e9f0 0%, #f1f5f9 100%);
                    --card-bg: rgba(255, 255, 255, 0.55);
                    --card-border: rgba(0, 0, 0, 0.06);
                    --text-color: #1e293b;
                    --text-secondary: rgba(30, 41, 59, 0.6);
                    --modal-bg: rgba(255, 255, 255, 0.95);
                }
            }
            body {
                margin: 0;
                padding: 20px 16px 36px 16px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
                background: var(--bg-gradient);
                color: var(--text-color);
                min-height: 100vh;
                display: flex;
                flex-direction: column;
                align-items: center;
                box-sizing: border-box;
                user-select: none;
                -webkit-user-select: none;
            }
            ::-webkit-scrollbar {
                display: none !important;
            }
            .header-bar {
                display: flex;
                justify-content: space-between;
                align-items: center;
                width: 100%;
                max-width: 340px;
                margin-top: 5px;
                margin-bottom: 20px;
            }
            .header-title {
                font-size: 20px;
                font-weight: 700;
                margin: 0;
                background: linear-gradient(135deg, #3b82f6 0%, #8b5cf6 100%);
                -webkit-background-clip: text;
                -webkit-text-fill-color: transparent;
            }
            .edit-btn {
                background: var(--card-bg);
                border: 1px solid var(--card-border);
                color: var(--text-color);
                padding: 5px 12px;
                border-radius: 8px;
                font-size: 11px;
                font-weight: 600;
                cursor: pointer;
                transition: all 0.15s ease;
                backdrop-filter: blur(10px);
                -webkit-backdrop-filter: blur(10px);
            }
            .edit-btn:active {
                transform: scale(0.95);
            }
            .edit-btn.active {
                background: #3b82f6;
                color: #ffffff;
                border-color: #3b82f6;
            }
            .grid {
                display: grid;
                grid-template-columns: repeat(3, 1fr);
                gap: 14px;
                width: 100%;
                max-width: 340px;
            }
            .site-card {
                position: relative;
                background: var(--card-bg);
                border: 1px solid var(--card-border);
                border-radius: 14px;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                padding: 12px 6px;
                text-decoration: none;
                color: inherit;
                transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
                backdrop-filter: blur(12px);
                -webkit-backdrop-filter: blur(12px);
                cursor: pointer;
                height: 90px;
                box-sizing: border-box;
            }
            .site-card:active:not(.editing) {
                transform: scale(0.93);
                background: rgba(255, 255, 255, 0.12);
            }
            .site-card.empty {
                border-style: dashed;
                background: rgba(255, 255, 255, 0.01);
            }
            @media (prefers-color-scheme: light) {
                .site-card.empty {
                    background: rgba(0, 0, 0, 0.01);
                }
            }
            .site-card.empty .icon-container {
                background: transparent;
                border: 1px dashed var(--card-border);
                box-shadow: none;
                color: var(--text-secondary);
                font-size: 24px;
                font-weight: 300;
            }
            .icon-container {
                width: 44px;
                height: 44px;
                border-radius: 11px;
                background: rgba(255, 255, 255, 0.95);
                display: flex;
                align-items: center;
                justify-content: center;
                margin-bottom: 8px;
                box-shadow: 0 4px 10px rgba(0,0,0,0.06);
                overflow: hidden;
                transition: transform 0.2s ease;
                font-size: 18px;
                font-weight: bold;
            }
            .site-card:hover:not(.editing) .icon-container {
                transform: translateY(-2px);
            }
            .icon-container img {
                width: 28px;
                height: 28px;
                object-fit: contain;
            }
            .site-name {
                font-size: 11px;
                font-weight: 500;
                text-align: center;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                width: 100%;
                color: var(--text-color);
            }
            .delete-badge {
                position: absolute;
                top: -6px;
                left: -6px;
                width: 20px;
                height: 20px;
                border-radius: 10px;
                background: #ef4444;
                color: #ffffff;
                display: none;
                align-items: center;
                justify-content: center;
                font-size: 12px;
                font-weight: bold;
                box-shadow: 0 2px 5px rgba(0,0,0,0.2);
                z-index: 10;
            }
            .editing .delete-badge {
                display: flex;
            }
            @keyframes shake {
                0% { transform: rotate(-1.5deg); }
                50% { transform: rotate(1.5deg); }
                100% { transform: rotate(-1.5deg); }
            }
            .editing.shake-card {
                animation: shake 0.25s infinite ease-in-out;
            }
            .grid a:nth-child(even).editing.shake-card {
                animation-duration: 0.23s;
                animation-delay: 0.05s;
            }
            .site-card.dragging {
                opacity: 0.5;
                transform: scale(0.95);
                border: 1px dashed #3b82f6;
                animation: none !important;
            }
            .modal-overlay {
                position: fixed;
                top: 0;
                left: 0;
                right: 0;
                bottom: 0;
                background: rgba(0,0,0,0.4);
                backdrop-filter: blur(8px);
                -webkit-backdrop-filter: blur(8px);
                display: none;
                align-items: center;
                justify-content: center;
                z-index: 100;
                padding: 20px;
            }
            .modal-content {
                background: var(--modal-bg);
                border: 1px solid var(--card-border);
                border-radius: 16px;
                width: 100%;
                max-width: 300px;
                padding: 20px;
                box-shadow: 0 10px 25px rgba(0,0,0,0.2);
                box-sizing: border-box;
                animation: scaleUp 0.25s cubic-bezier(0.34, 1.56, 0.64, 1);
            }
            @keyframes scaleUp {
                from { transform: scale(0.9); opacity: 0; }
                to { transform: scale(1); opacity: 1; }
            }
            .modal-title {
                font-size: 15px;
                font-weight: 600;
                margin-top: 0;
                margin-bottom: 15px;
                text-align: center;
            }
            .form-group {
                margin-bottom: 12px;
            }
            .form-group label {
                display: block;
                font-size: 11px;
                font-weight: 500;
                margin-bottom: 4px;
                color: var(--text-secondary);
            }
            .form-group input {
                width: 100%;
                background: rgba(0, 0, 0, 0.2);
                border: 1px solid var(--card-border);
                border-radius: 8px;
                padding: 8px 10px;
                font-size: 12px;
                color: var(--text-color);
                box-sizing: border-box;
                outline: none;
            }
            @media (prefers-color-scheme: light) {
                .form-group input {
                    background: rgba(0, 0, 0, 0.05);
                }
            }
            .form-group input:focus {
                border-color: #3b82f6;
            }
            .modal-actions {
                display: flex;
                justify-content: space-between;
                gap: 10px;
                margin-top: 18px;
            }
            .btn {
                flex: 1;
                padding: 8px;
                border-radius: 8px;
                font-size: 12px;
                font-weight: 600;
                border: none;
                cursor: pointer;
                transition: background 0.15s ease;
            }
            .btn-cancel {
                background: var(--card-bg);
                color: var(--text-color);
                border: 1px solid var(--card-border);
            }
            .btn-submit {
                background: #3b82f6;
                color: #ffffff;
            }
            
            /* 一键恢复配置长条卡片样式 */
            .preset-container {
                width: 100%;
                max-width: 340px;
                margin-top: 20px;
                display: flex;
                flex-direction: row; /* 横向一排显示两个 */
                gap: 10px;
            }
            .preset-card {
                position: relative; /* 启用绝对定位支持 x 按钮放置 */
                flex: 1; /* 平分空间 */
                background: var(--card-bg);
                border: 1px solid var(--card-border);
                backdrop-filter: blur(10px);
                -webkit-backdrop-filter: blur(10px);
                border-radius: 10px;
                padding: 8px 12px;
                display: flex;
                flex-direction: column; /* 内部内容垂直列式排布，节省横向空间 */
                align-items: flex-start;
                cursor: pointer;
                transition: all 0.2s ease;
                box-sizing: border-box;
                gap: 4px;
            }
            .preset-card:hover {
                background: rgba(255, 255, 255, 0.08);
                border-color: rgba(255, 255, 255, 0.2);
                transform: translateY(-1px);
            }
            @media (prefers-color-scheme: light) {
                .preset-card:hover {
                    background: rgba(255, 255, 255, 0.85);
                    border-color: rgba(0, 0, 0, 0.12);
                }
            }
            .preset-clear-btn {
                position: absolute;
                top: 6px;
                right: 8px;
                width: 14px;
                height: 14px;
                border-radius: 50%;
                background: rgba(0, 0, 0, 0.2);
                color: var(--text-secondary);
                font-size: 10px;
                font-weight: bold;
                display: none; /* 仅在保存后由 JS 动态显示 */
                align-items: center;
                justify-content: center;
                cursor: pointer;
                border: none;
                transition: all 0.15s ease;
                z-index: 10;
                padding: 0;
                line-height: 1;
            }
            .preset-clear-btn:hover {
                background: #ef4444; /* 红色高亮 */
                color: #ffffff;
            }
            @media (prefers-color-scheme: light) {
                .preset-clear-btn {
                    background: rgba(0, 0, 0, 0.06);
                }
            }
            .preset-title {
                font-size: 11px;
                font-weight: 600;
                color: var(--text-color);
                display: flex;
                align-items: center;
                gap: 5px;
            }
            .preset-subtitle {
                font-size: 9px;
                font-weight: 500;
                color: var(--text-secondary);
                transition: color 0.2s ease;
            }
            .color-picker {
                display: flex;
                gap: 8px;
                margin-top: 6px;
                margin-bottom: 6px;
            }
            .color-option {
                width: 24px;
                height: 24px;
                border-radius: 50%;
                cursor: pointer;
                border: 2px solid transparent;
                transition: all 0.15s ease;
                box-sizing: border-box;
            }
            .color-option:hover {
                transform: scale(1.1);
            }
            .color-option.selected {
                border-color: var(--text-color);
                box-shadow: 0 0 4px rgba(59, 130, 246, 0.5);
                transform: scale(1.1);
            }
        </style>
    </head>
    <body>
        <div class="header-bar">
            <h2 class="header-title">MenuDropX</h2>
            <button id="editBtn" class="edit-btn" onclick="toggleEditMode()">编辑列表</button>
        </div>
        <div class="grid" id="gridContainer"></div>
        
        <!-- 一键恢复配置长条卡片区 -->
        <div class="preset-container">
            <div class="preset-card" id="preset1" onclick="loadPreset(1)">
                <div class="preset-title" id="presetTitle1">📂 配置 1</div>
                <div class="preset-subtitle" id="presetSub1">未保存</div>
                <button class="preset-clear-btn" id="presetClear1" onclick="clearPreset(event, 1)">×</button>
            </div>
            <div class="preset-card" id="preset2" onclick="loadPreset(2)">
                <div class="preset-title" id="presetTitle2">📂 配置 2</div>
                <div class="preset-subtitle" id="presetSub2">未保存</div>
                <button class="preset-clear-btn" id="presetClear2" onclick="clearPreset(event, 2)">×</button>
            </div>
        </div>
        <div class="modal-overlay" id="addModal">
            <div class="modal-content">
                <h3 class="modal-title" id="modalTitle">添加自定义网站</h3>
                <div class="form-group">
                    <label for="siteName">网站名称</label>
                    <input type="text" id="siteName" placeholder="例如: 百度" autocomplete="off">
                </div>
                <div class="form-group">
                    <label for="siteUrl">网站网址</label>
                    <input type="text" id="siteUrl" placeholder="例如: baidu.com" autocomplete="off">
                </div>
                <div class="form-group">
                    <label for="siteIconText">文字图标 (可选，如：百 或 BD)</label>
                    <input type="text" id="siteIconText" placeholder="最多2个字母/1个中文字，留空则获取图标" autocomplete="off" maxlength="2">
                </div>
                <div class="form-group">
                    <label>文字图标背景 (可选)</label>
                    <div class="color-picker" id="colorPicker">
                        <div class="color-option selected" data-color="" onclick="setSelectedColor('')" style="background: linear-gradient(135deg, #9ca3af, #6b7280);" title="自动"></div>
                        <div class="color-option" data-color="red" onclick="setSelectedColor('red')" style="background: linear-gradient(135deg, #ff2442, #ff527b);" title="红色"></div>
                        <div class="color-option" data-color="orange" onclick="setSelectedColor('orange')" style="background: linear-gradient(135deg, #ffe411, #fbc02d);" title="橙色"></div>
                        <div class="color-option" data-color="green" onclick="setSelectedColor('green')" style="background: linear-gradient(135deg, #1aad19, #2ba245);" title="绿色"></div>
                        <div class="color-option" data-color="blue" onclick="setSelectedColor('blue')" style="background: linear-gradient(135deg, #3b82f6, #1d4ed8);" title="蓝色"></div>
                        <div class="color-option" data-color="purple" onclick="setSelectedColor('purple')" style="background: linear-gradient(135deg, #8b5cf6, #6d28d9);" title="紫色"></div>
                        <div class="color-option" data-color="grey" onclick="setSelectedColor('grey')" style="background: linear-gradient(135deg, #4b5563, #1f2937);" title="灰色"></div>
                    </div>
                </div>
                <div class="modal-actions">
                    <button class="btn btn-cancel" onclick="closeModal()">取消</button>
                    <button class="btn btn-submit" id="submitBtn" onclick="submitSite()">添加</button>
                </div>
            </div>
        </div>
        <script>
            const defaultSites = [
                { name: "Instagram", url: "https://www.instagram.com", domain: "instagram.com" },
                { name: "YouTube", url: "https://m.youtube.com", domain: "youtube.com" },
                { name: "X (Twitter)", url: "https://x.com", domain: "x.com" },
                { name: "Reddit", url: "https://www.reddit.com", domain: "reddit.com" },
                { name: "Google", url: "https://www.google.com", domain: "google.com" },
                { name: "Telegram", url: "https://web.telegram.org", domain: "telegram.org" },
                { name: "小红书", url: "https://www.xiaohongshu.com", domain: "xiaohongshu.com" },
                { name: "即刻", url: "https://web.okjike.com", domain: "okjike.com" },
                { name: "微信读书", url: "https://weread.qq.com", domain: "weread.qq.com" },
                { name: "微博", url: "https://m.weibo.cn", domain: "weibo.com" },
                { name: "Bilibili", url: "https://m.bilibili.com", domain: "bilibili.com" },
                { name: "滴答清单", url: "https://dida365.com", domain: "dida365.com" }
            ];
            let sites = [];
            let isEditing = false;
            let currentAddIndex = -1;
            function init() {
                try {
                    const stored = localStorage.getItem("menudropx_sites");
                    let loaded = false;
                    if (stored) {
                        try {
                            const parsed = JSON.parse(stored);
                            if (Array.isArray(parsed)) {
                                sites = parsed;
                                loaded = true;
                            }
                        } catch(e) {}
                    }
                    if (!loaded) {
                        sites = [...defaultSites];
                    }
                } catch(err) {
                    sites = [...defaultSites];
                }
                while(sites.length < 12) {
                    sites.push(null);
                }
                if (sites.length > 12) {
                    sites = sites.slice(0, 12);
                }
                try {
                    saveData();
                } catch(e) {}
                render();
                
                // 初始化加载配置预设状态
                updatePresets();
            }
            function saveData() {
                try {
                    localStorage.setItem("menudropx_sites", JSON.stringify(sites));
                } catch(e) {}
            }
            function getGradientForName(name, colorKey) {
                if (colorKey === "red") return "linear-gradient(135deg, #ff2442, #ff527b)";
                if (colorKey === "orange") return "linear-gradient(135deg, #ffe411, #fbc02d)";
                if (colorKey === "green") return "linear-gradient(135deg, #1aad19, #2ba245)";
                if (colorKey === "blue") return "linear-gradient(135deg, #3b82f6, #1d4ed8)";
                if (colorKey === "purple") return "linear-gradient(135deg, #8b5cf6, #6d28d9)";
                if (colorKey === "grey") return "linear-gradient(135deg, #4b5563, #1f2937)";
                
                if (!name) return "linear-gradient(135deg, #9ca3af, #6b7280)";
                if (name.includes("小红书")) return "linear-gradient(135deg, #ff2442, #ff527b)";
                if (name.includes("即刻")) return "linear-gradient(135deg, #ffe411, #fbc02d)";
                if (name.includes("微信") || name.includes("读书")) return "linear-gradient(135deg, #1aad19, #2ba245)";
                if (name.includes("微博")) return "linear-gradient(135deg, #e6162d, #ff5252)";
                if (name.includes("Bilibili") || name.includes("bilibili") || name.includes("B站")) return "linear-gradient(135deg, #fb7299, #ff9db5)";
                if (name.includes("滴答")) return "linear-gradient(135deg, #3763f6, #6b8eff)";
                let hash = 0;
                for (let i = 0; i < name.length; i++) {
                    hash = name.charCodeAt(i) + ((hash << 5) - hash);
                }
                const colors = [
                    ["#3b82f6", "#1d4ed8"],
                    ["#10b981", "#047857"],
                    ["#f59e0b", "#b45309"],
                    ["#ec4899", "#be185d"],
                    ["#8b5cf6", "#6d28d9"],
                    ["#ef4444", "#b91c1c"],
                    ["#06b6d4", "#0891b2"]
                ];
                const index = Math.abs(hash) % colors.length;
                return `linear-gradient(135deg, ${colors[index][0]}, ${colors[index][1]})`;
            }
            function getDisplayLetter(name) {
                if (!name) return "";
                const first = name.trim().charAt(0);
                if (/[a-zA-Z]/.test(first)) {
                    return first.toUpperCase();
                }
                return first;
            }
            window.handleIconError = function(img, name, domain, colorKey, index) {
                if (!img.dataset.triedGoogle) {
                    img.dataset.triedGoogle = "true";
                    const fallbackUrl = `https://www.google.com/s2/favicons?sz=128&domain=${domain}`;
                    img.src = fallbackUrl;
                    
                    // 将成功加载的 Google Favicon 地址保存回对应的数据卡片上，防止下次渲染再次触发加载延迟与白屏
                    if (index !== undefined && index !== null && sites[index]) {
                        sites[index].resolvedIcon = fallbackUrl;
                        saveData();
                    }
                } else {
                    img.style.display = 'none';
                    const parent = img.parentNode;
                    parent.style.background = getGradientForName(name, colorKey);
                    parent.style.color = '#ffffff';
                    parent.style.fontSize = '18px';
                    parent.style.fontWeight = '700';
                    parent.style.textShadow = '0 1px 2px rgba(0,0,0,0.15)';
                    parent.innerText = getDisplayLetter(name);
                }
            };
            window.toggleEditMode = function() {
                isEditing = !isEditing;
                const editBtn = document.getElementById("editBtn");
                if (isEditing) {
                    editBtn.innerText = "完成";
                    editBtn.classList.add("active");
                } else {
                    editBtn.innerText = "编辑列表";
                    editBtn.classList.remove("active");
                }
                render();
            };
            let draggedIndex = -1;
            window.dragStart = function(event, element, index) {
                if (!isEditing) return;
                draggedIndex = index;
                event.dataTransfer.effectAllowed = "move";
                event.dataTransfer.setData("text/plain", index);
                setTimeout(() => {
                    element.classList.add("dragging");
                }, 0);
            };
            window.dragEnd = function(event, element) {
                element.classList.remove("dragging");
                draggedIndex = -1;
            };
            window.dragOver = function(event) {
                if (!isEditing) return;
                event.preventDefault();
                event.dataTransfer.dropEffect = "move";
            };
            window.drop = function(event, targetIndex) {
                if (!isEditing) return;
                event.preventDefault();
                if (draggedIndex === -1 || draggedIndex === targetIndex) return;
                
                const temp = sites[draggedIndex];
                sites[draggedIndex] = sites[targetIndex];
                sites[targetIndex] = temp;
                
                saveData();
                render();
            };
            window.handleCardClick = function(index) {
                const site = sites[index];
                if (isEditing) {
                    openModal(index);
                    return;
                }
                if (site) {
                    window.location.href = site.url;
                } else {
                    openModal(index);
                }
            };
            window.deleteSite = function(event, index) {
                event.stopPropagation();
                sites[index] = null;
                saveData();
                render();
            };
            
            let selectedColor = "";
            window.setSelectedColor = function(color) {
                selectedColor = color;
                const options = document.querySelectorAll(".color-option");
                options.forEach(opt => {
                    if (opt.getAttribute("data-color") === color) {
                        opt.classList.add("selected");
                    } else {
                        opt.classList.remove("selected");
                    }
                });
            };
            
            function openModal(index) {
                currentAddIndex = index;
                const site = sites[index];
                const modalTitle = document.getElementById("modalTitle");
                const submitBtn = document.getElementById("submitBtn");
                
                if (site) {
                    modalTitle.innerText = "编辑自定义网站";
                    submitBtn.innerText = "保存修改";
                    document.getElementById("siteName").value = site.name || "";
                    document.getElementById("siteUrl").value = site.url || "";
                    document.getElementById("siteIconText").value = site.iconText || "";
                    setSelectedColor(site.iconColor || "");
                } else {
                    modalTitle.innerText = "添加自定义网站";
                    submitBtn.innerText = "添加";
                    document.getElementById("siteName").value = "";
                    document.getElementById("siteUrl").value = "";
                    document.getElementById("siteIconText").value = "";
                    setSelectedColor("");
                }
                
                document.getElementById("addModal").style.display = "flex";
                document.getElementById("siteName").focus();
            }
            window.closeModal = function() {
                document.getElementById("addModal").style.display = "none";
                currentAddIndex = -1;
            };
            window.submitSite = function() {
                const nameInput = document.getElementById("siteName").value.trim();
                let urlInput = document.getElementById("siteUrl").value.trim();
                let iconTextVal = document.getElementById("siteIconText").value.trim();
                
                if (!nameInput || !urlInput) {
                    alert("请填写完整的网站名称和网址");
                    return;
                }
                if (!urlInput.toLowerCase().startsWith("http://") && !urlInput.toLowerCase().startsWith("https://")) {
                    urlInput = "https://" + urlInput;
                }
                let domain = "";
                try {
                    const tempUrl = new URL(urlInput);
                    domain = tempUrl.hostname.replace("www.", "");
                } catch(e) {
                    domain = urlInput;
                }
                
                // 限制文字图标：1个中文 或 最多2个英文
                if (iconTextVal) {
                    const isChinese = /[^\\x00-\\xff]/.test(iconTextVal);
                    if (isChinese) {
                        iconTextVal = iconTextVal.substring(0, 1);
                    } else {
                        iconTextVal = iconTextVal.substring(0, 2);
                    }
                }
                
                sites[currentAddIndex] = {
                    name: nameInput,
                    url: urlInput,
                    domain: domain,
                    iconText: iconTextVal || undefined,
                    iconColor: selectedColor || undefined
                };
                saveData();
                closeModal();
                isEditing = false;
                const editBtn = document.getElementById("editBtn");
                editBtn.innerText = "编辑列表";
                editBtn.classList.remove("active");
                render();
            };
            function render() {
                const container = document.getElementById("gridContainer");
                container.innerHTML = "";
                sites.forEach((site, index) => {
                    if (site) {
                        const classes = ["site-card", isEditing ? "editing shake-card" : ""].filter(Boolean).join(" ");
                        let iconHtml = "";
                        if (site.iconText) {
                            iconHtml = `
                                <div class="icon-container" style="background: ${getGradientForName(site.name, site.iconColor)}; color: #ffffff; font-size: 18px; font-weight: 700; text-shadow: 0 1px 2px rgba(0,0,0,0.15);">
                                    ${site.iconText}
                                </div>
                            `;
                        } else {
                            const favSrc = site.resolvedIcon || `https://${site.domain}/favicon.ico`;
                            iconHtml = `
                                <div class="icon-container">
                                    <img src="${favSrc}" onerror="handleIconError(this, '${site.name}', '${site.domain}', '${site.iconColor || ''}', ${index})">
                                </div>
                            `;
                        }
                        container.innerHTML += `
                            <a class="${classes}" 
                               draggable="${isEditing ? 'true' : 'false'}"
                               ondragstart="dragStart(event, this, ${index})" 
                               ondragend="dragEnd(event, this)" 
                               ondragover="dragOver(event)" 
                               ondrop="drop(event, ${index})"
                               onclick="handleCardClick(${index})">
                                <div class="delete-badge" onclick="deleteSite(event, ${index})">×</div>
                                ${iconHtml}
                                <div class="site-name">${site.name}</div>
                            </a>
                        `;
                    } else {
                        const classes = ["site-card", "empty", isEditing ? "editing" : ""].filter(Boolean).join(" ");
                        container.innerHTML += `
                            <a class="${classes}" 
                               ondragover="dragOver(event)" 
                               ondrop="drop(event, ${index})"
                               onclick="handleCardClick(${index})">
                                <div class="icon-container">+</div>
                                <div class="site-name">添加</div>
                            </a>
                        `;
                    }
                });
            }
            window.updatePresetUI = function() {
                updatePresets();
            };
            
            function updatePresets() {
                const presets = window.menudropx_presets;
                for (let id = 1; id <= 2; id++) {
                    const titleEl = document.getElementById("presetTitle" + id);
                    const subEl = document.getElementById("presetSub" + id);
                    const clearEl = document.getElementById("presetClear" + id);
                    if (!titleEl || !subEl) continue;
                    
                    const key = "preset" + id;
                    if (presets && presets[key] && presets[key].saved) {
                        titleEl.innerText = `📂 配置 ${id}`;
                        subEl.innerText = presets[key].name || "已保存";
                        subEl.style.color = "#10b981";
                        if (clearEl) clearEl.style.display = "flex"; // 显示清空按钮
                    } else {
                        titleEl.innerText = `📂 配置 ${id}`;
                        subEl.innerText = "未保存";
                        subEl.style.color = "var(--text-secondary)";
                        if (clearEl) clearEl.style.display = "none"; // 隐藏清空按钮
                    }
                }
            }
            
            window.loadPreset = function(id) {
                const presets = window.menudropx_presets;
                if (!presets || !presets["preset" + id] || !presets["preset" + id].saved) {
                    alert("该配置插槽尚未保存，请点击右下角电源键，选择“保存为配置”进行保存");
                    return;
                }
                window.location.href = "menudropx://loadconfig?id=" + id;
            };
            
            window.clearPreset = function(event, id) {
                event.stopPropagation(); // 阻止点击事件穿透到父卡片触发加载
                window.location.href = "menudropx://deleteconfig?id=" + id;
            };
            
            document.addEventListener("DOMContentLoaded", init);
        </script>
    </body>
    </html>
    """
    
    /// 静态广播：遍历当前所有活跃的真实 WKWebView 并尝试注入最新配置
    /// （JS 侧的 window.updatePresetUI 只在首页 HTML 中定义，非首页调用无副作用）
    static func broadcastSyncPresets() {
        activeWebViews.removeAll { $0.webView == nil }
        for wrapper in activeWebViews {
            if let webView = wrapper.webView {
                WebView.injectPresetsDataStatic(to: webView)
            }
        }
    }
    
    /// 通过 WebViewModel 实例指针查找对应的真实 WKWebView 并返回当前 URL
    /// - Returns: 实际页面 URL（首页返回 "menudropx://home"，未找到返回 nil）
    static func currentURLForViewModel(_ viewModel: WebViewModel) -> String? {
        activeWebViews.removeAll { $0.webView == nil }
        for wrapper in activeWebViews {
            guard let wv = wrapper.webView, wrapper.viewModel === viewModel else { continue }
            if wv.url?.host == "menudropx.local" {
                return "menudropx://home"
            } else if let urlStr = wv.url?.absoluteString, !urlStr.isEmpty {
                return urlStr
            }
            return nil
        }
        return nil
    }
    
    // 核心数据注入：直接向 WKWebView 的全局变量写入当前最准确的 UserDefaults 预设状态
    static func injectPresetsDataStatic(to webView: WKWebView) {
        let p1Saved = UserDefaults.standard.data(forKey: "menudropx_preset_1") != nil
        let p1Name = UserDefaults.standard.string(forKey: "menudropx_preset_name_1") ?? "未保存"
        
        let p2Saved = UserDefaults.standard.data(forKey: "menudropx_preset_2") != nil
        let p2Name = UserDefaults.standard.string(forKey: "menudropx_preset_name_2") ?? "未保存"
        
        let p1NameEscaped = p1Name.replacingOccurrences(of: "'", with: "\\'")
        let p2NameEscaped = p2Name.replacingOccurrences(of: "'", with: "\\'")
        
        // 注入全局变量并调用刷新函数（非首页 window.updatePresetUI 为 undefined，调用无副作用）
        let js = """
        window.menudropx_presets = {
            preset1: { saved: \(p1Saved), name: '\(p1NameEscaped)' },
            preset2: { saved: \(p2Saved), name: '\(p2NameEscaped)' }
        };
        if (typeof window.updatePresetUI === 'function') {
            window.updatePresetUI();
        }
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

class WeakWKWebView {
    weak var webView: WKWebView?
    weak var viewModel: WebViewModel?
    init(_ webView: WKWebView, viewModel: WebViewModel) {
        self.webView = webView
        self.viewModel = viewModel
    }
}


