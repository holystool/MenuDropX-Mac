import SwiftUI
import Combine

class WebViewModel: ObservableObject {
    // 默认首屏加载的主页 URL 常数，供后续修改
    static let homeURLString = "menudropx://home"
    
    // 地址栏的双向绑定文本
    @Published var urlInput: String = WebViewModel.homeURLString
    
    // 窗口尺寸，支持动态拖拽 and 预设尺寸切换
    @Published var windowWidth: CGFloat = 375 {
        didSet {
            onSizeChanged?(CGSize(width: windowWidth, height: windowHeight))
        }
    }
    @Published var windowHeight: CGFloat = 667 {
        didSet {
            onSizeChanged?(CGSize(width: windowWidth, height: windowHeight))
        }
    }
    
    // 当前网页对应的 favicon 图标（模板单色剪影版，NSImage）
    @Published var currentFavicon: NSImage? = nil {
        didSet {
            onFaviconChanged?(currentFavicon)
        }
    }
    
    // 当前网页对应的 favicon 图标（高保真原始彩色版，NSImage）
    @Published var currentFaviconColor: NSImage? = nil
    
    // 钉住（常驻）状态。开启后点击外部 Popover 不会消失。
    @Published var isPinned: Bool = false {
        didSet {
            onPinChanged?(isPinned)
        }
    }
    
    // 是否为桌面端 User-Agent，默认为 false（手机端）
    @Published var isDesktopUA: Bool = false
    
    // 网页加载相关的状态，由 WebView 实时更新回传
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    
    // 是否正在翻译过程中，用于驱动 UI 展示加载状态
    @Published var isTranslating: Bool = false
    
    // 当前页面是否已被翻译过（用于底栏按钮变蓝状态及双向还原逻辑）
    @Published var isPageTranslated: Bool = false
    
    // 网页控制动作枚举，用于单向命令传递
    enum WebAction: Equatable {
        case none
        case goBack
        case goForward
        case reload
        case load(String)
        case loadHome
    }
    
    // 当前待执行的网页操作，由 View 修改，WebView 监听并执行
    @Published var action: WebAction = .none
    
    // 供底层的真实 WKWebView 注册的主动控制闭包，避开 SwiftUI 的 updateNSView 异步响应延迟
    var loadURLExecutor: ((String) -> Void)?
    var loadHomeExecutor: (() -> Void)?
    var goBackExecutor: (() -> Void)?
    var goForwardExecutor: (() -> Void)?
    var reloadExecutor: (() -> Void)?
    var evaluateJSExecutor: ((String) -> Void)?

    // 供 AppDelegate 监听的 Pin 状态改变回调
    var onPinChanged: ((Bool) -> Void)?
    
    // 供多实例管理器监听的尺寸变化回调
    var onSizeChanged: ((CGSize) -> Void)?
    
    // 供多实例管理器监听的图标变化回调
    var onFaviconChanged: ((NSImage?) -> Void)?
    
    // 供 View 触发新建窗口和关闭窗口的闭包
    var onCreateNewInstance: (() -> Void)?
    var onCloseInstance: (() -> Void)?
    
    // MARK: - 意图控制方法
    
    /// 后退
    func goBack() {
        if let executor = goBackExecutor {
            executor()
        } else {
            action = .goBack
        }
    }
    
    /// 前进
    func goForward() {
        if let executor = goForwardExecutor {
            executor()
        } else {
            action = .goForward
        }
    }
    
    /// 刷新
    func reload() {
        if let executor = reloadExecutor {
            executor()
        } else {
            action = .reload
        }
        isPageTranslated = false
    }
    
    /// 返回主页
    func loadHome() {
        if let executor = loadHomeExecutor {
            executor()
        } else {
            action = .loadHome
        }
        isPageTranslated = false
    }
    
    /// 加载指定的 URL 地址
    /// - Parameter urlStr: 网页地址，如未携带协议头会自动补充 https://
    func loadURL(_ urlStr: String) {
        var cleanURL = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }
        
        // 自动补充 https:// 协议头
        if !cleanURL.lowercased().hasPrefix("http://") && !cleanURL.lowercased().hasPrefix("https://") {
            cleanURL = "https://" + cleanURL
        }
        
        if let executor = loadURLExecutor {
            executor(cleanURL)
        } else {
            action = .load(cleanURL)
        }
        isPageTranslated = false
    }
    
    /// 执行自定义的 JavaScript 脚本，直接作用于底层的真实网页中
    func evaluateJS(_ jsCode: String) {
        evaluateJSExecutor?(jsCode)
    }
}
