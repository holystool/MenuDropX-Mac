import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: WebViewModel
    
    // 记录拖拽缩放开始时的窗口大小
    @State private var dragStartSize: CGSize = .zero
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部精美控制栏
            HStack(spacing: 4) {
                // 后退按钮
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(viewModel.canGoBack ? .primary : .secondary.opacity(0.4))
                }
                .buttonStyle(ControlButtonStyle(isDisabled: !viewModel.canGoBack))
                .disabled(!viewModel.canGoBack)
                .help("后退")
                
                // 前进按钮
                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(viewModel.canGoForward ? .primary : .secondary.opacity(0.4))
                }
                .buttonStyle(ControlButtonStyle(isDisabled: !viewModel.canGoForward))
                .disabled(!viewModel.canGoForward)
                .help("前进")
                
                // 刷新按钮
                Button(action: { viewModel.reload() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .buttonStyle(ControlButtonStyle())
                .help("刷新")
                
                // 主页按钮
                Button(action: { viewModel.loadHome() }) {
                    Image(systemName: "house")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .buttonStyle(ControlButtonStyle())
                .help("返回主页")
                
                // 地址栏输入框
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    
                    TextField("搜索或网址并回车", text: $viewModel.urlInput, onCommit: {
                        viewModel.loadURL(viewModel.urlInput)
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .disableAutocorrection(true)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                // 动态适配系统深浅色背景
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                

                // 新建浏览器窗口按钮
                Button(action: { viewModel.onCreateNewInstance?() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                }
                .buttonStyle(ControlButtonStyle())
                .help("新建浏览器窗口")
                
                // Pin（置顶常驻）按钮
                Button(action: { viewModel.isPinned.toggle() }) {
                    Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(viewModel.isPinned ? .accentColor : .primary)
                }
                .buttonStyle(ControlButtonStyle())
                .help(viewModel.isPinned ? "取消常驻" : "常驻置顶")
                
                // 关闭当前窗口按钮
                Button(action: { viewModel.onCloseInstance?() }) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                }
                .buttonStyle(ControlButtonStyle())
                .help("关闭当前窗口")
                
                // 退出应用按钮 (原色电源图标，点击时通过 NSMenu 原生弹出菜单，无下拉三角)
                Button(action: {
                    AppDelegate.shared?.showPowerMenu()
                }) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(ControlButtonStyle())
                .help("保存配置或退出应用")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(VisualEffectView()) // 磨砂玻璃背板
            
            // 极简蓝紫渐变加载进度条
            LoadingProgressBar(isLoading: viewModel.isLoading)
            
            // 主体 WebView 区域
            WebView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // 底部精致状态栏
            Divider()
            HStack(spacing: 8) {
                // 左侧显示当前的 UA 类型（正在翻译时动态切换为高亮提示）
                Text(viewModel.isTranslating ? "正在翻译..." : (viewModel.isDesktopUA ? "桌面模式" : "手机模式"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(viewModel.isTranslating ? .accentColor : .secondary)
                
                Spacer()
                
                // 网页翻译按钮
                let hasValidURL = !viewModel.urlInput.isEmpty && viewModel.urlInput != "menudropx://home"
                let isBtnDisabled = !hasValidURL || viewModel.isTranslating
                Button(action: {
                    let jsCode = """
                    (function() {
                        var IGNORE_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'IFRAME', 'CODE', 'PRE', 'TEXTAREA']);
                        
                        // 1. 如果当前已经是“翻译”状态，点击则执行一秒瞬时倒带（无感恢复原文）
                        if (window.menuDropXIsTranslated) {
                            // 恢复所有的普通 TextNode 原始文本
                            if (window.menuDropXActiveNodesBackup) {
                                window.menuDropXActiveNodesBackup.forEach(function(node) {
                                    if (node && node.menuDropXOriginalText !== undefined) {
                                        node.nodeValue = node.menuDropXOriginalText;
                                    }
                                });
                            }
                            
                            // 移去所有动态追加的对照翻译 Div 节点
                            var transDivs = document.querySelectorAll('.menudropx-translated-text');
                            transDivs.forEach(function(el) { el.remove(); });
                            
                            // 清除所有容器节点的 data-translated-container 标记
                            var containers = document.querySelectorAll('[data-translated-container]');
                            containers.forEach(function(el) { el.removeAttribute('data-translated-container'); });
                            
                            // 断开 MutationObserver，静默停止滚动监听
                            if (window.menuDropXObserver) {
                                window.menuDropXObserver.disconnect();
                                window.menuDropXObserver = null;
                            }
                            
                            // 移除点击事件监听
                            if (window.menuDropXClickHandler) {
                                document.removeEventListener('click', window.menuDropXClickHandler, true);
                                window.menuDropXClickHandler = null;
                            }
                            
                            window.menuDropXPendingQueue = [];
                            window.menuDropXActiveNodesBackup = [];
                            window.menuDropXIsTranslated = false;
                            
                            // 同步更新 Swift 侧的状态栏按钮颜色
                            window.webkit.messageHandlers.menuDropXTranslate.postMessage({
                                type: 'status',
                                isTranslated: false
                            });
                            return;
                        }
                        

                        // 只翻译主体为英文的文本（ASCII字母占比 > 40%）
                        function isEnglishText(text) {
                            if (!text || text.length < 2) return false;
                            var letters = (text.match(/[a-zA-Z]/g) || []).length;
                            return letters / text.length > 0.4;
                        }
                        
                        // 3. 递归文本节点收集（在游离节点上备份 OriginalText 供双向倒带还原）
                        if (!window.menuDropXActiveNodesBackup) {
                            window.menuDropXActiveNodesBackup = [];
                        }
                        
                        function collectTextNodes(node, nodes, containerSet) {
                            if (node.nodeType === Node.ELEMENT_NODE) {
                                var tagName = node.tagName.toUpperCase();
                                if (IGNORE_TAGS.has(tagName) || node.isContentEditable) { return; }
                                if (containerSet && containerSet.has(node)) { return; }
                                
                                // X/Reddit 容器：已翻译过则跳过整个子树，否则继续递归
                                var isX = node.getAttribute && node.getAttribute('data-testid') === 'tweetText';
                                var isReddit = node.classList && (node.classList.contains('RichTextJSON-root') || node.getAttribute && node.getAttribute('data-click-id') === 'text');
                                if ((isX || isReddit) && node.getAttribute('data-translated-container')) {
                                    return; // 已翻译，跳过
                                }
                            }
                            
                            if (node.nodeType === Node.TEXT_NODE) {
                                var val = node.nodeValue.trim();
                                // 只收集主体为英文的文本节点
                                if (isEnglishText(val)) {
                                    if (node.menuDropXOriginalText === undefined) {
                                        node.menuDropXOriginalText = node.nodeValue;
                                        window.menuDropXActiveNodesBackup.push(node);
                                        nodes.push({ type: 'text', el: node, text: node.nodeValue });
                                    } else if (node.menuDropXOriginalText !== node.nodeValue) {
                                        // 检查这是否是我们自己添加双语对照导致的变化
                                        // 如果当前 nodeValue 刚好是以 "原文 + 换行" 开头，说明这是我们刚回填的，忽略它以打破无限循环
                                        if (node.nodeValue.indexOf(node.menuDropXOriginalText + "\\n\\n") === 0) {
                                            return;
                                        }
                                        
                                        // 否则就是 React 在原地修改了文本节点（例如 X 展开 "Show more"）
                                        // 则更新备份并重新送译
                                        node.menuDropXOriginalText = node.nodeValue;
                                        nodes.push({ type: 'text', el: node, text: node.nodeValue });
                                    }
                                }
                                return;
                            }
                            
                            var child = node.firstChild;
                            while (child) {
                                collectTextNodes(child, nodes, containerSet);
                                child = child.nextSibling;
                            }
                        }
                        
                        var allActiveItems = [];
                        collectTextNodes(document.body, allActiveItems, null);
                        
                        if (allActiveItems.length > 0) {
                            window.menuDropXActiveItems = allActiveItems;
                            var texts = allActiveItems.map(function(item) { return item.text; });
                            
                            window.menuDropXIsTranslated = true;
                            window.webkit.messageHandlers.menuDropXTranslate.postMessage({
                                type: 'status',
                                isTranslated: true
                            });
                            
                            window.webkit.messageHandlers.menuDropXTranslate.postMessage({
                                type: 'full-page',
                                texts: texts
                            });
                        }
                        
                        // 4. 注册 MutationObserver，监视无限滚动并自动在后台增量翻译新内容
                        if (window.menuDropXObserver) {
                            window.menuDropXObserver.disconnect();
                        }
                        
                        var observer = new MutationObserver(function(mutations) {
                            var incrementalNodes = [];
                            mutations.forEach(function(mutation) {
                                if (mutation.type === 'childList') {
                                    mutation.addedNodes.forEach(function(addedNode) {
                                        collectTextNodes(addedNode, incrementalNodes, null);
                                    });
                                } else if (mutation.type === 'characterData') {
                                    collectTextNodes(mutation.target, incrementalNodes, null);
                                }
                            });
                            
                            if (incrementalNodes.length > 0) {
                                if (!window.menuDropXPendingQueue) {
                                    window.menuDropXPendingQueue = [];
                                }
                                var taskId = "task_" + Date.now() + "_" + Math.random().toString(36).substr(2, 5);
                                window.menuDropXPendingQueue.push({
                                    id: taskId,
                                    items: incrementalNodes
                                });
                                
                                var texts = incrementalNodes.map(function(item) { return item.text; });
                                window.webkit.messageHandlers.menuDropXTranslate.postMessage({
                                    type: 'incremental',
                                    taskId: taskId,
                                    texts: texts
                                });
                            }
                        });
                        
                        observer.observe(document.body, {
                            childList: true,
                            subtree: true,
                            characterData: true

                        });
                        
                        // 5. 监听点击事件，处理 X "显示更多" 展开后回滚为英文的问题
                        if (!window.menuDropXClickHandler) {
                            window.menuDropXClickHandler = function() {
                                if (!window.menuDropXIsTranslated) return;
                                
                                function scanNewNodes() {
                                    var newNodes = [];
                                    collectTextNodes(document.body, newNodes, null);
                                    if (newNodes.length > 0) {
                                        if (!window.menuDropXPendingQueue) {
                                            window.menuDropXPendingQueue = [];
                                        }
                                        var taskId = "task_" + Date.now() + "_click";
                                        window.menuDropXPendingQueue.push({ id: taskId, items: newNodes });
                                        window.webkit.messageHandlers.menuDropXTranslate.postMessage({
                                            type: 'incremental',
                                            taskId: taskId,
                                            texts: newNodes.map(function(n) { return n.text; })
                                        });
                                    }
                                }
                                
                                // 多级延时兜底，应对不同网络环境下的展开渲染延迟
                                setTimeout(scanNewNodes, 400);
                                setTimeout(scanNewNodes, 800);
                                setTimeout(scanNewNodes, 1500);
                            };
                            document.addEventListener('click', window.menuDropXClickHandler, true);
                        }
                        window.menuDropXObserver = observer;
                    })();
                    """
                    viewModel.evaluateJS(jsCode)
                }) {
                    Image(systemName: "translate")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(hasValidURL ? (viewModel.isPageTranslated ? .accentColor : .primary) : .secondary.opacity(0.4))
                }
                .buttonStyle(ControlButtonStyle(isDisabled: isBtnDisabled))
                .disabled(isBtnDisabled)
                .help("翻译当前网页（双向切换）")
                
                // 浏览器标识切换按钮
                Button(action: {
                    viewModel.isDesktopUA.toggle()
                }) {
                    Image(systemName: viewModel.isDesktopUA ? "laptopcomputer" : "iphone")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.primary)
                }
                .buttonStyle(ControlButtonStyle())
                .help(viewModel.isDesktopUA ? "切换到手机标识" : "切换到桌面标识")
                
                // 尺寸预设菜单
                Menu {
                    Button("iPhone SE (375 × 667)") {
                        viewModel.windowWidth = 375
                        viewModel.windowHeight = 667
                    }
                    Button("iPhone Pro (390 × 844)") {
                        viewModel.windowWidth = 390
                        viewModel.windowHeight = 844
                    }
                    Button("iPad Mini (768 × 1024)") {
                        viewModel.windowWidth = 768
                        viewModel.windowHeight = 1024
                    }
                    Button("Desktop Light (1024 × 768)") {
                        viewModel.windowWidth = 1024
                        viewModel.windowHeight = 768
                    }
                    Button("MacBook Light (1280 × 800)") {
                        viewModel.windowWidth = 1280
                        viewModel.windowHeight = 800
                    }
                } label: {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 24)
                .help("选择预设尺寸")
                
                // 占位符：为右侧的 32px 矩形拖动区域空出专属物理空间，防止按钮和点阵重叠，并实现三者等比美观分布
                Color.clear
                    .frame(width: 22, height: 24)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(VisualEffectView())
            .overlay(
                // 右下角点阵拖动感应与 Canvas 笔直斜切点阵区域 (绝对贴边且无任何多余缝隙)
                Canvas { context, size in
                    let dotSize: CGFloat = 1.5
                    let spacing: CGFloat = 3.0
                    
                    // 用绝对几何网格铺满整个 32x24 的矩形空间，完美回应以尺寸按钮右侧边缘为界的点阵排列
                    let cols = Int(size.width / spacing)
                    let rows = Int(size.height / spacing)
                    
                    for row in 0..<rows {
                        let y = size.height - dotSize / 2 - CGFloat(row) * spacing
                        for col in 0..<cols {
                            let x = size.width - dotSize / 2 - CGFloat(col) * spacing
                            let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                            let path = Path(ellipseIn: rect)
                            context.fill(path, with: .color(Color.secondary.opacity(0.6)))
                        }
                    }
                }
                .frame(width: 32, height: 24) // 增大到 32 像素以覆写底栏 10px 边距，令点阵紧贴最右边缘
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        getDiagonalCursor().set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartSize == .zero {
                                dragStartSize = CGSize(width: viewModel.windowWidth, height: viewModel.windowHeight)
                            }
                            let newWidth = max(280, dragStartSize.width + value.translation.width)
                            let newHeight = max(350, dragStartSize.height + value.translation.height)
                            viewModel.windowWidth = newWidth
                            viewModel.windowHeight = newHeight
                        }
                        .onEnded { _ in
                            dragStartSize = .zero
                        }
                ),
                alignment: .bottomTrailing
            )
        }
        // 绑定数据模型中的尺寸，以便自由缩放和一键切换
        .frame(width: viewModel.windowWidth, height: viewModel.windowHeight)
    }
    
    /// 获取 macOS 系统标准的对角线大小调整光标
    private func getDiagonalCursor() -> NSCursor {
        let selector = Selector(("_windowResizeNorthWestSouthEastCursor"))
        if NSCursor.responds(to: selector),
           let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return NSCursor.resizeLeftRight
    }
}

// MARK: - 辅助微动画按钮 Style
struct ControlButtonStyle: ButtonStyle {
    var isDisabled: Bool = false
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && !isDisabled ? Color.primary.opacity(0.1) : Color.clear)
            )
            // 点击时的微收缩动画
            .scaleEffect(configuration.isPressed && !isDisabled ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - 系统磨砂毛玻璃视图
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        // Popover 专属材质，具备完美的系统级毛玻璃自适应深浅色效果
        view.material = .popover
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 2px 蓝紫渐变动态加载条
struct LoadingProgressBar: View {
    let isLoading: Bool
    @State private var phase: CGFloat = -0.5
    
    var body: some View {
        ZStack(alignment: .leading) {
            Color.primary.opacity(0.04) // 底色线条
            
            if isLoading {
                GeometryReader { geo in
                    let gradient = LinearGradient(
                        colors: [Color.blue, Color.purple, Color.blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    Rectangle()
                        .fill(gradient)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: phase * geo.size.width)
                        .onAppear {
                            // 开启循环动画，形成跑马灯式加载流动感
                            withAnimation(Animation.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                                phase = 1.0
                            }
                        }
                }
            }
        }
        .frame(height: 2)
    }
}
