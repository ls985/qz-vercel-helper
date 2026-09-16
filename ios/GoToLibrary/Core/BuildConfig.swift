// 对应 Android 侧 android/app/build.gradle 的 buildConfigField / resValue 与
// 生成的 com.gotolibrary.app.BuildConfig。
import Foundation
import UIKit

/// 构建期常量。值通过编译条件或 Info.plist 注入，默认值与 Android release 变体对齐。
///
/// 发版前必须替换两处：
///   1. `licensePublicKey` —— 服务端 ECDSA P-256 公钥（DER/SPKI base64），
///      管理面板"APK 设备"页可复制；留空则验签 fail-closed，一切凭证被拒。
///   2. `licenseSPKIPins`  —— 服务器证书链的 SPKI SHA-256（`openssl s_client -connect host:443`
///      取出证书后对 SubjectPublicKeyInfo 求 SHA-256，再 base64 成 `sha256/<base64>`）；
///      留空则自签 IP 证书无法建立信任，激活与打码接口都连不上。
enum BuildConfig {

    // MARK: - 地址

    /// 许可（激活 / 续签）接口基址。
    static var licenseAPIBase: String {
        #if DEBUG
        return plistValue("LicenseAPIBase") ?? "http://127.0.0.1:3990/api/device/"
        #else
        return plistValue("LicenseAPIBase") ?? "https://120.27.227.206/api/device/"
        #endif
    }

    /// 打码中转基址。与许可服务同服务器、同一套 SPKI 固定。
    static var captchaAPIBase: String {
        #if DEBUG
        return plistValue("CaptchaAPIBase") ?? "http://127.0.0.1:3990/api/captcha/"
        #else
        return plistValue("CaptchaAPIBase") ?? "https://120.27.227.206/api/captcha/"
        #endif
    }

    /// 更新包基址。iOS 不能自安装 APK，这里只用于查询 version.json 取版本号，
    /// 发现新版本后跳转下载页 / App Store（见 AppUpdater）。
    static var updateBase: String {
        #if DEBUG
        return plistValue("UpdateBase") ?? "http://127.0.0.1:3990/apk/"
        #else
        return plistValue("UpdateBase") ?? "http://120.27.227.206/apk/"
        #endif
    }

    /// iOS 更新清单文件名。**不能**复用 Android 的 version.json：服务端那份由
    /// android/build-apk.ps1 从 android/app/build.gradle 生成，versionCode 是 Android 的
    /// 构建号（bump 节奏与 iOS 无关），也没有 iosUrl 字段。iOS 读它只会把
    /// "Android 发了新包"误判成"iOS 有新版本"，点下载打开的还是一个 APK 目录。
    static var updateManifestName: String {
        plistValue("UpdateManifestName") ?? "version-ios.json"
    }

    /// iOS 下载页 / App Store 地址。iOS 不能自安装，一条可用的更新提示必须落到用户
    /// 能真正完成安装的地址上；留空时 AppUpdater 不弹提示（弹了也无处可去）。
    static var updatePageURL: String {
        plistValue("UpdatePageURL") ?? ""
    }

    // MARK: - 会员入口

    /// 会员卡密购买渠道（淘宝链接）
    static var purchaseURL: String {
        plistValue("PurchaseURL") ?? "https://m.tb.cn/h.8saq3FN?tk=Lg2XTjavlOo"
    }

    /// 淘口令完整文案（带短链）
    static let taobaoTokenText = "79￥ CZ0001 Lg2XTjavlOo￥ https://m.tb.cn/h.8saq3FN?tk=Lg2XTjavlOo"

    /// 购买卡密智能跳转渠道：先复制淘口令，优先唤起闲鱼，次选淘宝，兜底打开浏览器
    static func openPaymentChannel() {
        UIPasteboard.general.string = taobaoTokenText
        if let xianyuUrl = URL(string: "fleamarket://"), UIApplication.shared.canOpenURL(xianyuUrl) {
            UIApplication.shared.open(xianyuUrl)
            return
        }
        if let taobaoUrl = URL(string: "taobao://"), UIApplication.shared.canOpenURL(taobaoUrl) {
            UIApplication.shared.open(taobaoUrl)
            return
        }
        if let url = URL(string: purchaseURL) {
            UIApplication.shared.open(url)
        }
    }

    /// 详细使用教程（金山文档）
    static var tutorialURL: String {
        plistValue("TutorialURL") ?? "https://www.kdocs.cn/l/cuqkJGWxsz2n"
    }

    // MARK: - 信任锚

    /// 服务端 ECDSA P-256 公钥（DER/SPKI base64）。debug 用联调配对公钥，
    /// release 用正式服务端公钥。留空 → LicenseManager 拒绝一切凭证（fail-closed）。
    static var licensePublicKey: String {
        #if DEBUG
        return plistValue("LicensePublicKey")
            ?? "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6FWKOgeTnCsO4nEG1niOOdcaAuRho7T9YWldwD4u45w2cpkTTgvfJFKK3k5M+/TKVaQs1O+BFT4zmlHH1buXGw=="
        #else
        return plistValue("LicensePublicKey")
            ?? "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4ee2ZPMpI8xq3M5dv02heY4VPaL785+TC/cSMVLs1JLdF8mi4gOuq74pTDZSLIy+yhfGFcIMNiqdlN1oifPR4g=="
        #endif
    }

    /// 许可 / 打码服务的证书 SPKI SHA-256 固定值，格式 `sha256/<base64>`。
    /// 这是自签 IP 证书的唯一信任锚：命中即放行，不做系统 CA 与主机名校验。
    /// 服务器换证书时必须同步更新并重新发版，否则激活直接失败。
    /// Info.plist 里可用逗号分隔多个指纹，便于轮换期同时接受新旧证书。
    static var licenseSPKIPins: [String] {
        if let raw = plistValue("LicenseSPKIPins"), !raw.isEmpty {
            return raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        return ["sha256/6gKK6e/e21R0JtWagsehCa/VqlL58q6Gy838emip2eY="]
    }

    /// 仅 debug 联调允许明文基址（127.0.0.1 走 adb reverse）。release 恒为 false：
    /// 非 https 基址会被 LicenseClient 直接拒绝并报"许可服务未配置"。
    static var licenseAllowHTTP: Bool {
        #if DEBUG
        return plistBool("LicenseAllowHTTP") ?? true
        #else
        return plistBool("LicenseAllowHTTP") ?? false
        #endif
    }

    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - 应用版本

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// `CFBundleVersion` 整数化，用于与 version.json 的 versionCode 比较。
    /// 非数字形态（如 patch 号）取前缀数字，取不到按 0。
    static var appBuildCode: Int {
        var digits = ""
        for character in appBuild.trimmingCharacters(in: .whitespaces) {
            if character.isNumber { digits.append(character) } else { break }
        }
        return Int(digits) ?? 0
    }

    // MARK: - Info.plist 覆盖

    /// 允许 Info.plist 覆盖构建常量，便于不重新编译就切环境；缺省回退编译期默认值。
    private static func plistValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func plistBool(_ key: String) -> Bool? {
        guard let raw = plistValue(key) else { return nil }
        let lowered = raw.lowercased()
        return lowered == "1" || lowered == "true" || lowered == "yes"
    }
}
