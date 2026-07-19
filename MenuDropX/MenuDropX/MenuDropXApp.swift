import SwiftUI

@main
struct MenuDropXApp: App {
    // 桥接经典的 AppKit AppDelegate，用于管理菜单栏图标和 Popover 窗口的生命周期
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // 使用 Settings 场景代替 WindowGroup，防止应用启动时弹出默认的空白窗口。
        // 这样可以确保应用是纯粹的菜单栏（MenuBar Only）形态。
        Settings {
            EmptyView()
        }
    }
}
