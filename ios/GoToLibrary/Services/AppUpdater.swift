// 对应 Android 侧 com.gotolibrary.app.AppUpdater 的 checkLatest 部分。
//
// 平台差异（与 Android 的关键分歧）：
// - iOS 应用**不能自安装**：没有 DownloadManager，也没有"安装未知来源应用"的等价能力，
//   App Store 之外只能由用户在自己信任的流程里安装（TestFlight / 描述文件 / 侧载工具）。
//   所以这里只做「查版本 → 返回弹窗数据」，下载与安装那两步（Android 的 download/install）
//   在 iOS 上直接砍掉，由用户点击后自行打开下载页。
// - 更新清单走明文 HTTP（IP 自签证书在 iOS 上无法通过 ATS/系统 CA 校验），因此 Info.plist
//   必须对 120.27.227.206 开 NSExceptionAllowsInsecureHTTPLoads。清单用的是 iOS 自己的
//   文件名（BuildConfig.updateManifestName），不是 Android 的 version.json —— 那份的
//   versionCode 是 Android 构建号，iOS 读它必然误报新版本。这里拿到的只是"有没有新版本"
//   的展示信息，即使被篡改也无法让应用装上来路不明的包。
import Foundation
import os

enum AppUpdater {

    /// 一次版本检查的结果。versionCode 大于本机才需要更新。
    /// `url` 交给调用方用 `UIApplication.shared.open` 打开（下载页或 App Store 链接）。
    struct Release {
        let version: String
        let versionCode: Int
        let notes: String
        let url: String
    }

    /// !force 时的最小检查间隔。Android 是每次启动检查一次（进程生命周期天然限流），
    /// iOS 的 UI 可能被频繁唤起，用时间窗替代进程生命周期做限流。
    static let minCheckInterval: TimeInterval = 6 * 3600

    private static let log = Logger(subsystem: "com.gotolibrary.nativeapp", category: "update")

    /// 拉 version.json，与本地 versionCode 比较，发现更高版本返回 Release；否则返回 nil。
    /// 任何失败（网络、解析、无新版本）都静默返回 nil —— 更新检查不该打断抢座流程。
    static func checkForUpdate(force: Bool = false) async -> Release? {
        if !force, let last = AppConfig.lastUpdateCheckAt(),
           Date().timeIntervalSince(last) < minCheckInterval {
            return nil
        }
        let base = BuildConfig.updateBase.hasSuffix("/") ? BuildConfig.updateBase : BuildConfig.updateBase + "/"
        guard let url = URL(string: base + BuildConfig.updateManifestName) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 上游静态目录可能有缓存副本，用 no-cache 保证拿到刚发布的版本号。
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 签名不允许向上抛（更新检查失败一律静默），这里包括 URLSession 在任务取消时
            // 抛出的 URLError(.cancelled)：调用方靠 Task.isCancelled 自己收尾。
            AppUpdater.log.warning("版本检查失败（静默处理）: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            AppUpdater.log.warning("版本检查失败（静默处理）: HTTP 非 200")
            return nil
        }
        AppConfig.setLastUpdateCheckAt(Date())

        return parse(data)
    }

    private static func parse(_ data: Data) -> Release? {
        // 服务器可能带 UTF-8 BOM，JSONSerialization 不认，先剥掉。
        var payload = data
        if payload.count >= 3, payload[payload.startIndex] == 0xEF,
           payload[payload.startIndex + 1] == 0xBB, payload[payload.startIndex + 2] == 0xBF {
            payload = payload.dropFirst(3)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            AppUpdater.log.warning("版本信息解析失败")
            return nil
        }
        let versionCode = intValue(json["versionCode"]) ?? 0
        let installed = BuildConfig.appBuildCode
        guard versionCode > installed else {
            AppUpdater.log.info("已是最新：server=\(versionCode) installed=\(installed)")
            return nil
        }
        // 下载地址优先取 iOS 专用字段；都没有时退回配置的下载页/App Store 地址。
        // 取不到任何 iOS 可用地址就不弹提示 —— iOS 不能自安装，指向 APK 目录只会误导用户。
        let iosURL = stringValue(json["iosUrl"])
        let generic = stringValue(json["url"])
        let url = !iosURL.isEmpty ? iosURL
            : (!generic.isEmpty ? generic : BuildConfig.updatePageURL)
        guard !url.isEmpty else {
            AppUpdater.log.warning("有新版本但未配置 iOS 下载地址，跳过提示")
            return nil
        }
        AppUpdater.log.info("有新版本：server=\(versionCode) installed=\(installed)")
        let version = stringValue(json["versionName"])
        let notes = stringValue(json["notes"])
        return Release(version: version.isEmpty ? String(versionCode) : version,
                       versionCode: versionCode,
                       notes: notes,
                       url: url)
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
