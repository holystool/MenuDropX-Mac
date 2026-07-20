import Cocoa
import SwiftUI
import CoreImage

struct WindowConfig: Codable {
    let url: String
    let width: CGFloat
    let height: CGFloat
    let isDesktopUA: Bool
}

struct AppPresetConfig: Codable {
    let id: Int
    let windows: [WindowConfig]
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    
    // 保存所有活跃的浏览器实例
    var instances: [BrowserInstance] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        // 冷启动自动清理旧 Favicons 缓存目录，防止读取到旧损坏算法生成的“方块”图标
        let fileManager = FileManager.default
        if let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let subDir = cachesDir.appendingPathComponent("lch.MenuDropX/Favicons")
            try? fileManager.removeItem(at: subDir)
        }
        
        // 启动时自动创建第一个默认实例
        createNewInstance()
        
        // 启动时自动检查更新
        checkForUpdates()
    }
    
    /// 自动检查 GitHub 最新 Release 版本并提醒跳转下载
    func checkForUpdates() {
        let githubOwner = "holystool"
        let githubRepo = "MenuDropX-Mac"
        
        let apiURLString = "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest"
        guard let url = URL(string: apiURLString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8.0
        // GitHub API 强制要求设置 User-Agent，否则会拦截返回 403
        request.setValue("MenuDropX-mac-UpdateChecker", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if error != nil { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlUrlString = json["html_url"] as? String,
                  let htmlURL = URL(string: htmlUrlString) else { return }
            
            // 获取当前软件的本地版本号
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            
            // 清理 tag_name 的 "v" 前缀（例如 "v1.1.0" -> "1.1.0"）
            let cleanTagName = tagName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            
            // 按照数字版本号规则对比：如果线上版本号 > 当前运行版本号
            if cleanTagName.compare(currentVersion, options: .numeric) == .orderedDescending {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "发现新版本 \(tagName)"
                    
                    // 获取 GitHub Release 的描述作为更新说明
                    let bodyText = json["body"] as? String ?? "无更新说明。"
                    alert.informativeText = "当前版本: \(currentVersion)\n最新版本: \(cleanTagName)\n\n更新日志:\n\(bodyText)"
                    
                    alert.addButton(withTitle: "前往下载")
                    alert.addButton(withTitle: "以后再说")
                    alert.alertStyle = .informational
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        // 唤醒默认浏览器打开 GitHub Release 网页
                        NSWorkspace.shared.open(htmlURL)
                    }
                }
            }
        }.resume()
    }
    
    /// 创建并添加一个新的浏览器实例
    /// - Parameter url: 可选的初始加载 URL
    func createNewInstance(url: String? = nil) {
        let viewModel = WebViewModel()
        if let url = url {
            viewModel.urlInput = url
        }
        let instance = BrowserInstance(viewModel: viewModel, manager: self)
        instances.append(instance)
        
        // 延迟一小会儿，等待视图层级就绪后，自动弹出新实例的 Popover
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            instance.showPopover(nil)
        }
    }
    
    /// 安全销毁并移除指定的浏览器实例
    /// - Parameter instance: 待销毁的实例
    func removeInstance(_ instance: BrowserInstance) {
        instance.destroy()
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances.remove(at: index)
        }
        
        // 如果最后一个窗口也被关闭，则彻底退出整个应用程序
        if instances.isEmpty {
            NSApp.terminate(nil)
        }
    }
    
    /// 关闭所有未被 Pin（钉住）的其它 Popover 窗口
    /// - Parameter currentInstance: 当前正在操作激活的实例，该实例不受影响
    func closeAllNonPinnedPopovers(except currentInstance: BrowserInstance) {
        for instance in instances {
            if instance.id != currentInstance.id && !instance.viewModel.isPinned {
                instance.closePopover(nil)
            }
        }
    }
    
    /// 保存当前所有开启的窗口配置 (id: 1 或 2)
    func savePresetConfig(id: Int, name: String) {
        let windows = instances.map { instance in
            // 从真实 WKWebView 读取当前 URL（WebView.swift 内部负责 WebKit 访问，避免跨模块类型依赖）
            let realURL = WebView.currentURLForViewModel(instance.viewModel)
            // 回退策略：真实 URL 不可用时用 urlInput，仍为空则记为首页
            let url = realURL
                ?? (instance.viewModel.urlInput.isEmpty ? "menudropx://home" : instance.viewModel.urlInput)
            return WindowConfig(
                url: url,
                width: instance.viewModel.windowWidth,
                height: instance.viewModel.windowHeight,
                isDesktopUA: instance.viewModel.isDesktopUA
            )
        }
        
        let preset = AppPresetConfig(id: id, windows: windows)
        if let data = try? JSONEncoder().encode(preset) {
            UserDefaults.standard.set(data, forKey: "menudropx_preset_\(id)")
            UserDefaults.standard.set(name, forKey: "menudropx_preset_name_\(id)")
            
            // 广播写入所有活跃的 WebView 缓存，使之瞬时完成 UI 同步重绘
            WebView.broadcastSyncPresets()
        }
    }
    
    /// 清空指定 id 的预设配置并同步界面
    func deletePresetConfig(id: Int) {
        UserDefaults.standard.removeObject(forKey: "menudropx_preset_\(id)")
        UserDefaults.standard.removeObject(forKey: "menudropx_preset_name_\(id)")
        WebView.broadcastSyncPresets()
    }
    
    /// 弹出原生确认弹窗并清空预设配置
    func confirmAndDeletePresetConfig(id: Int) {
        DispatchQueue.main.async {
            let presetName = UserDefaults.standard.string(forKey: "menudropx_preset_name_\(id)") ?? "未命名配置"
            
            let alert = NSAlert()
            alert.messageText = "确定要清空配置 \(id) 吗？"
            alert.informativeText = "清空后，“\(presetName)”的窗口大小与链接等配置信息将被彻底抹除且无法恢复。"
            alert.addButton(withTitle: "确定清空")
            alert.addButton(withTitle: "取消")
            
            NSApp.activate(ignoringOtherApps: true)
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.deletePresetConfig(id: id)
            }
        }
    }
    
    /// 弹出原生命名弹窗，让用户输入配置名称，并在保存后不退出应用
    func promptForPresetName(id: Int) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "保存当前窗口为配置 \(id)"
            alert.informativeText = "请输入这份配置的个性化名称："
            alert.addButton(withTitle: "保存")
            alert.addButton(withTitle: "取消")
            
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            textField.placeholderString = "例如：我的工作台"
            if let existingName = UserDefaults.standard.string(forKey: "menudropx_preset_name_\(id)") {
                textField.stringValue = existingName
            } else {
                textField.stringValue = "配置 \(id)"
            }
            alert.accessoryView = textField
            
            // 激活应用以保证 Alert 能被顶到最上层显示
            NSApp.activate(ignoringOtherApps: true)
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalName = name.isEmpty ? "配置 \(id)" : name
                self.savePresetConfig(id: id, name: finalName)
            }
        }
    }
    
    /// 由窗口内红色电源键点击触发的原生 NSMenu 下拉弹出框
    @objc func showPowerMenu() {
        let menu = NSMenu()
        
        let save1 = NSMenuItem(title: "保存为配置 1", action: #selector(menuSave1), keyEquivalent: "")
        save1.target = self
        menu.addItem(save1)
        
        let save2 = NSMenuItem(title: "保存为配置 2", action: #selector(menuSave2), keyEquivalent: "")
        save2.target = self
        menu.addItem(save2)
        
        menu.addItem(NSMenuItem.separator())
        
        let quit = NSMenuItem(title: "退出应用", action: #selector(menuQuitDirect), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        
        // 在鼠标当前屏幕绝对坐标位置弹出，无下拉三角，原生态且完美贴合原有电源键样式
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    
    @objc private func menuSave1() {
        promptForPresetName(id: 1)
    }
    
    @objc private func menuSave2() {
        promptForPresetName(id: 2)
    }
    
    @objc private func menuQuitDirect() {
        NSApp.terminate(nil)
    }
    
    /// 一键加载指定预设配置，并将触发的窗口作为首窗口原地重装，其余窗口多开生成
    func loadPresetConfig(id: Int, fromInstance: BrowserInstance) {
        guard let data = UserDefaults.standard.data(forKey: "menudropx_preset_\(id)"),
              let preset = try? JSONDecoder().decode(AppPresetConfig.self, from: data) else {
            return
        }
        
        let configs = preset.windows
        guard !configs.isEmpty else { return }
        
        // 1. 批量创建后续的多开窗口实例 (从第二个窗口配置开始)
        for i in 1..<configs.count {
            let conf = configs[i]
            let viewModel = WebViewModel()
            viewModel.windowWidth = conf.width
            viewModel.windowHeight = conf.height
            viewModel.isDesktopUA = conf.isDesktopUA
            // 关键修复：在创建 BrowserInstance（即创建 SwiftUI 视图）之前就写入正确的 URL。
            // makeNSView 初次渲染时会读取 urlInput 直接加载，不依赖后续异步 action 机制，
            // 从根本上规避了 closeAllNonPinnedPopovers 关闭 popover 后 updateNSView 不被调用的竞态问题。
            viewModel.urlInput = conf.url
            
            let instance = BrowserInstance(viewModel: viewModel, manager: self)
            self.instances.append(instance)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
                instance.showPopover(nil)
                // 不再需要设置 action，makeNSView 已经通过 urlInput 直接加载了正确 URL
            }
        }
        
        // 2. 原地装载配置中的第一个窗口，防止当前窗口闪烁
        let firstConfig = configs[0]
        fromInstance.viewModel.windowWidth = firstConfig.width
        fromInstance.viewModel.windowHeight = firstConfig.height
        fromInstance.viewModel.isDesktopUA = firstConfig.isDesktopUA
        fromInstance.popover?.contentSize = NSSize(width: firstConfig.width, height: firstConfig.height)
        if firstConfig.url == "menudropx://home" {
            fromInstance.viewModel.action = .loadHome
        } else {
            fromInstance.viewModel.action = .load(firstConfig.url)
        }
    }
}

/// 承载单个状态栏浏览器窗口的实例类
class BrowserInstance: NSObject, NSMenuDelegate {
    let id = UUID()
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let viewModel: WebViewModel
    var eventMonitor: EventMonitor?
    weak var manager: AppDelegate?
    var colorFavicon: NSImage? = nil
    var templateFavicon: NSImage? = nil
    var isActive: Bool = false
    
    init(viewModel: WebViewModel, manager: AppDelegate) {
        self.viewModel = viewModel
        self.manager = manager
        super.init()
        setupInstance()
    }
    
    private func setupInstance() {
        // 1. 创建并配置承载 SwiftUI 视图的 NSPopover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: viewModel.windowWidth, height: viewModel.windowHeight)
        popover.behavior = .applicationDefined
        
        let contentView = ContentView(viewModel: viewModel)
        popover.contentViewController = NSHostingController(rootView: contentView)
        self.popover = popover
        
        // 2. 创建系统菜单栏（Status Bar）图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let pinImage = NSImage(systemSymbolName: "pin", accessibilityDescription: "MenuDropX")
            pinImage?.isTemplate = true
            button.image = pinImage
            
            // 设置按钮支持左键和右键鼠标事件响应
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
        }
        
        // 3. 绑定数据模型的回调通知
        viewModel.onPinChanged = { [weak self] isPinned in
            self?.handlePinChange(isPinned: isPinned)
        }
        
        viewModel.onSizeChanged = { [weak self] size in
            self?.popover?.contentSize = size
        }
        
        viewModel.onCreateNewInstance = { [weak self] in
            self?.manager?.createNewInstance()
        }
        
        viewModel.onCloseInstance = { [weak self] in
            guard let self = self else { return }
            self.manager?.removeInstance(self)
        }
        
        viewModel.onFaviconChanged = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.colorFavicon = self.viewModel.currentFaviconColor
                self.templateFavicon = self.viewModel.currentFavicon
                self.updateStatusItemImage()
            }
        }
        
        // 4. 初始化外部点击事件监听器
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let popover = self.popover else { return }
            if popover.isShown {
                if !self.viewModel.isPinned {
                    self.closePopover(event)
                }
            }
        }
    }
    
    @objc func handleStatusItemClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        // 如果是右键点击，或者按住 Control 键的点击，则弹出上下文菜单
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            // 普通左键点击切换 Popover 显示状态
            togglePopover(sender)
        }
    }
    
    func togglePopover(_ sender: AnyObject?) {
        guard let popover = popover else { return }
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }
    
    func showPopover(_ sender: AnyObject?) {
        self.isActive = true
        guard let button = statusItem?.button, let popover = popover else { return }
        
        // 先收起其它未被钉住的浏览器 Popover
        manager?.closeAllNonPinnedPopovers(except: self)
        
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
        }
        
        if !viewModel.isPinned {
            eventMonitor?.start()
        }
        
        updateStatusItemImage()
    }
    
    func closePopover(_ sender: AnyObject?) {
        self.isActive = false
        popover?.close()
        eventMonitor?.stop()
        
        updateStatusItemImage()
    }
    
    private func handlePinChange(isPinned: Bool) {
        if isPinned {
            eventMonitor?.stop()
        } else {
            if let popover = popover, popover.isShown {
                eventMonitor?.start()
            }
        }
    }
    
    /// 根据当前窗口激活状态（Popover 是否展开），自动切换显示高保真彩色图标或黑白模板图标
    /// 根据当前窗口激活状态，更新对应的彩色菜单栏图标（利用子视图展示彩色Favicon，避开系统的inactive自动淡化机制）
    /// 根据当前窗口激活状态，更新彩色图标
    func updateStatusItemImage() {
        guard let button = statusItem?.button else { return }
        
        guard let favicon = self.colorFavicon else {
            // 没有自定义网页图标，展示系统默认大头针
            let pinImage = NSImage(systemSymbolName: "pin", accessibilityDescription: "MenuDropX")
            pinImage?.isTemplate = true
            button.image = pinImage
            return
        }
        
        // 直接使用高品质彩色 Favicon
        button.image = favicon
    }
    
    /// 弹出自定义的右键菜单
    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        let newWindowItem = NSMenuItem(title: "新建浏览器窗口", action: #selector(menuNewWindow), keyEquivalent: "n")
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        
        let closeWindowItem = NSMenuItem(title: "关闭当前窗口", action: #selector(menuCloseWindow), keyEquivalent: "w")
        closeWindowItem.target = self
        menu.addItem(closeWindowItem)
        
        // 在“关闭当前窗口”下面新增一个“保存配置”，子菜单分为“配置 1”、“配置 2”
        let saveConfigItem = NSMenuItem(title: "保存配置", action: nil, keyEquivalent: "")
        let saveSubmenu = NSMenu()
        
        let savePreset1 = NSMenuItem(title: "配置 1", action: #selector(menuSaveAndQuit1), keyEquivalent: "")
        savePreset1.target = self
        saveSubmenu.addItem(savePreset1)
        
        let savePreset2 = NSMenuItem(title: "配置 2", action: #selector(menuSaveAndQuit2), keyEquivalent: "")
        savePreset2.target = self
        saveSubmenu.addItem(savePreset2)
        
        saveConfigItem.submenu = saveSubmenu
        menu.addItem(saveConfigItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 退出 MenuDropX 直接放到第一层
        let quitItem = NSMenuItem(title: "退出 MenuDropX", action: #selector(menuQuitDirect), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        if let button = statusItem?.button {
            // 在按钮正下方弹出菜单
            let origin = NSPoint(x: 0, y: button.frame.height + 4)
            menu.popUp(positioning: nil, at: origin, in: button)
        }
    }
    
    @objc private func menuNewWindow() {
        manager?.createNewInstance()
    }
    
    @objc private func menuCloseWindow() {
        manager?.removeInstance(self)
    }
    
    @objc private func menuSaveAndQuit1() {
        manager?.promptForPresetName(id: 1)
    }
    
    @objc private func menuSaveAndQuit2() {
        manager?.promptForPresetName(id: 2)
    }
    
    @objc private func menuQuitDirect() {
        NSApp.terminate(nil)
    }
    
    /// 清理状态栏图标和监听器资源
    func destroy() {
        closePopover(nil)
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
        self.popover = nil
        self.eventMonitor = nil
    }
    
    
    /// 彩色和单色双图标一站式高保真处理方法
    static func processFaviconDual(image: NSImage) -> (color: NSImage, template: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (image, image)
        }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 1. 读取原始图像像素
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (image, image) }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixelData = context.data else { return (image, image) }
        let pixels = pixelData.assumingMemoryBound(to: UInt8.self)

        // 2. 扫描并裁剪紧凑边界（避免 Favicon 本身自带大空白边导致缩放后偏小）
        var minX = width, maxX = 0
        var minY = height, maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let alpha = pixels[offset + 3]
                if alpha > 15 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }

        let contentRect: CGRect
        if maxX >= minX && maxY >= minY {
            let cropMinX = max(0, minX - 1)
            let cropMinY = max(0, minY - 1)
            let cropMaxX = min(width - 1, maxX + 1)
            let cropMaxY = min(height - 1, maxY + 1)
            contentRect = CGRect(x: cropMinX, y: cropMinY, width: cropMaxX - cropMinX + 1, height: cropMaxY - cropMinY + 1)
        } else {
            contentRect = CGRect(x: 0, y: 0, width: width, height: height)
        }

        guard let croppedCG = cgImage.cropping(to: contentRect) else {
            return (image, image)
        }

        // 3. 新建标准的 16x16 画布
        let targetSize = NSSize(width: 16, height: 16)

        // A. 渲染高保真彩色图标
        guard let colorCtx = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16 * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (image, image) }

        let croppedW = CGFloat(croppedCG.width)
        let croppedH = CGFloat(croppedCG.height)
        let maxDrawDim: CGFloat = 13.0
        let scale = min(maxDrawDim / croppedW, maxDrawDim / croppedH)
        let drawW = croppedW * scale
        let drawH = croppedH * scale
        let drawX = (16.0 - drawW) / 2.0
        let drawY = (16.0 - drawH) / 2.0

        colorCtx.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
        colorCtx.draw(croppedCG, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

        guard let finalColorCG = colorCtx.makeImage() else { return (image, image) }
        let processedColor = NSImage(cgImage: finalColorCG, size: targetSize)
        processedColor.isTemplate = false

        return (processedColor, processedColor)
    }

    /// 向后兼容的剪影化接口，直接获取 processFaviconDual 的单色版本
    static func makeSystemStyleSilhouette(image: NSImage) -> NSImage {
        return processFaviconDual(image: image).template
    }
}

/// 全局事件监听器，用于捕捉应用窗口外部的鼠标点击事件
class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void
    
    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }
    
    deinit {
        stop()
    }
    
    /// 开始监听全局鼠标按下事件
    func start() {
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        }
    }
    
    /// 停止监听
    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
