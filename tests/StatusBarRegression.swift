// 与 QuotaPing.swift 拼接编译，验证真实 Combine 订阅及菜单 tracking run loop。
extension QuotaEngine {
    func publishForRegression(_ value: QuotaStatus) { status = value }
}

extension ReachabilityEngine {
    func publishForRegression(_ value: NetStatus) { status = value }
}

extension StatusBarController {
    func runRegressionChecks() {
        func drain(_ mode: RunLoop.Mode) {
            let deadline = Date().addingTimeInterval(0.05)
            while Date() < deadline {
                _ = RunLoop.main.run(mode: mode, before: deadline)
            }
        }
        func publishQuota(_ five: Int?, _ week: Int?, credits: Double? = nil) {
            quota.publishForRegression(.ok(
                plan: "pro",
                fiveHour: five.map { QuotaWindow(usedPercent: $0, resetAt: Date().addingTimeInterval(3600)) },
                weekly: week.map { QuotaWindow(usedPercent: $0, resetAt: Date().addingTimeInterval(86400)) },
                credits: credits
            ))
        }

        // 首次响应后无需等待下一轮网络检测或额度刷新。
        quota.publishForRegression(.loading)
        drain(.default)
        publishQuota(23, 42)
        drain(.default)
        assert(item.button?.image?.accessibilityDescription?.contains("5 小时剩余 77%") == true)
        assert(item.button?.image?.accessibilityDescription?.contains("周剩余 58%") == true)

        let menu = item.menu!
        menuWillOpen(menu)
        let refreshItem = menu.items.first { $0.title == "立即刷新" }!
        let frequencyItem = menu.items.first { $0.title == "额度刷新频率" }!

        // 模拟菜单展开时的 run loop 模式，额度、网络状态均应更新。
        publishQuota(35, nil, credits: 10)
        ping.publishForRegression(.ok(rtt: 25))
        drain(.eventTracking)
        assert(menu.items.contains { $0.title.contains("剩 65%") })
        assert(!menu.items.contains { $0.title.hasPrefix("1周：") })
        assert(menu.items.contains { $0.title == "credits：10" })
        assert(menu.items.first?.title == "google.com：正常（25ms）")
        assert(item.button?.image?.accessibilityDescription?.contains("5 小时剩余 65%") == true)

        // 数据行从错误提示扩展成双窗口再缩短，操作项保持同一个对象。
        quota.publishForRegression(.unavailable(reason: "测试错误"))
        drain(.eventTracking)
        assert(liveMenuItems.count == 2)
        publishQuota(10, 20, credits: 5)
        drain(.eventTracking)
        assert(liveMenuItems.count == 5)
        assert(menu.items.contains { $0 === refreshItem })
        assert(menu.items.contains { $0 === frequencyItem })
        assert(menu.items[liveMenuItems.count].isSeparatorItem)

        menuDidClose(menu)
        publishQuota(nil, 50)
        drain(.default)
        menuWillOpen(menu)
        assert(menu.items.contains { $0.title.contains("1周：剩 50%") })
        assert(!menu.items.contains { $0.title.hasPrefix("5 小时：") })
        menuDidClose(menu)
    }
}

let regressionApp = NSApplication.shared
regressionApp.setActivationPolicy(.accessory)
let regressionController = StatusBarController(
    ping: ReachabilityEngine(),
    quota: QuotaEngine(),
    updaterController: SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
)
regressionController.runRegressionChecks()
print("PASS: startup quota rendering and live menu updates")
