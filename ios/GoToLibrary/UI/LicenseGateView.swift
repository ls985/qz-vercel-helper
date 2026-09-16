// 对应 Android 侧 MainActivity 的会员激活门禁（licensePanel + activateLicense / refreshLicense）。
import SwiftUI
import UIKit

@MainActor
struct LicenseGateView: View {

    @ObservedObject private var themeStore = ThemeStore.shared

    private var colors: ThemeColors { themeStore.colors }

    @State private var code = ""
    @State private var state: LicenseState = .none
    @State private var busy = false
    @State private var statusMessage = ""
    @State private var statusIsError = false

    init() {}

    var body: some View {
        ZStack {
            GlassBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    deviceCodeCard
                    activationCard
                    stateCard
                }
                .padding(.horizontal, 22)
                .padding(.top, 36)
                .padding(.bottom, 40)
            }
        }
        .onAppear { state = LicenseManager.currentState() }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("会员激活")
                .font(.largeTitle.weight(.bold))
                .foregroundColor(colors.ink)
            Text("输入卡密激活本设备后使用全部功能")
                .font(.footnote)
                .foregroundColor(colors.secondaryText)
        }
    }

    // MARK: - 设备码

    private var deviceCodeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionBar("本机设备码（客服核对用）")
                Text(LicenseManager.displayDeviceCode())
                    .font(.system(.title3, design: .monospaced))
                    .foregroundColor(colors.ink)
                    .textSelection(.enabled)
                Button("复制设备码") {
                    UIPasteboard.general.string = LicenseManager.displayDeviceCode()
                    statusMessage = "设备码已复制"
                    statusIsError = false
                }
                .buttonStyle(GlassSecondaryButtonStyle())
            }
        }
    }

    // MARK: - 激活

    private var activationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("会员卡密")
                TextField("卡密格式：CDK-XXXXX-XXXXX-XXXXX-XXXXX", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .disabled(busy)
                Button(busy ? "处理中…" : "激活本设备") {
                    activate()
                }
                .buttonStyle(GlassPrimaryButtonStyle())
                .disabled(busy)

                Button(busy ? "校验中…" : "我已完成激活，重新校验") {
                    recheck()
                }
                .buttonStyle(GlassSecondaryButtonStyle())
                .disabled(busy)

                HStack(spacing: 10) {
                    Button("获取卡密 / 购买会员") {
                        BuildConfig.openPaymentChannel()
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                    Button("使用教程") {
                        if let url = URL(string: BuildConfig.tutorialURL) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: - 状态

    private var stateCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionBar("会员状态")
                Text(stateDescription)
                    .font(.footnote)
                    .foregroundColor(state == .active ? colors.ink : colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if state == .active, !expiryText.isEmpty {
                    Text(expiryText)
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                }
                Text("上次复验：\(lastRefreshText)")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(statusIsError ? colors.danger : colors.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var stateDescription: String {
        switch state {
        case .active: return "尊享会员生效中"
        case .none: return "本设备尚未激活，请输入卡密开通会员。"
        case .expired: return "会员已到期，请续费卡密后重新激活。"
        case .stale: return "长时间未联网校验会员，请连接网络后重试。"
        case .tampered: return "应用完整性校验失败，请从官方渠道重新安装。"
        case .hostile: return "检测到不安全的运行环境（Root/框架），为保护会员权益已锁定。"
        }
    }

    private var expiryText: String {
        let expiresAt = LicenseManager.membershipExpiresAt()
        guard expiresAt > 0 else { return "" }
        return "，有效期至 " + LicenseGateView.dateFormatter.string(from: Date(timeIntervalSince1970: expiresAt))
    }

    private var lastRefreshText: String {
        guard let last = LicenseManager.lastRefreshAt() else { return "尚未复验" }
        return LicenseGateView.dateTimeFormatter.string(from: last)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - 网络动作

    private func activate() {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            statusMessage = "本设备尚未激活，请输入卡密开通会员。"
            statusIsError = true
            return
        }
        busy = true
        statusMessage = ""
        Task {
            do {
                let body = try await LicenseClient().activate(code: trimmed,
                                                              deviceId: LicenseManager.deviceFingerprint(),
                                                              deviceName: UIDevice.current.name)
                handleResponse(body)
            } catch {
                statusMessage = friendly(error)
                statusIsError = true
            }
            busy = false
        }
    }

    /// 手动复验：本地已有凭证时向服务端续签一次；没有凭证就只重算本地状态
    /// （对齐 Android licenseRecheckButton → refreshLicense → refreshEntitlement）。
    private func recheck() {
        busy = true
        statusMessage = ""
        Task {
            let hasToken = LicenseManager.entitlementToken() != nil
            if hasToken {
                do {
                    let body = try await LicenseClient().refreshEntitlement(
                        deviceId: LicenseManager.deviceFingerprint(),
                        nonce: String(Int(Date().timeIntervalSince1970 * 1000)))
                    handleResponse(body)
                } catch {
                    statusMessage = friendly(error)
                    statusIsError = true
                    state = LicenseManager.currentState()
                }
            } else {
                state = LicenseManager.currentState()
                statusMessage = stateDescription
                statusIsError = state != .active
                AppConfig.addLog("会员状态已重新校验")
            }
            busy = false
        }
    }

    /// 解析激活/续签响应。`storeVerifiedToken` 验签不通过时会自己清掉脏凭证。
    private func handleResponse(_ body: String) {
        switch LicenseManager.acceptResponse(body) {
        case .stored:
            state = LicenseManager.currentState()
            statusMessage = state == .active ? "激活成功" : stateDescription
            statusIsError = state != .active
            AppConfig.addLog("会员激活成功，设备码 \(LicenseManager.displayDeviceCode())")
            // 门禁的显示状态由 MainView 决定，这里额外广播一次变更，方便它据此重算并放行。
            NotificationCenter.default.post(name: .goToLibraryLicenseChanged, object: nil)
        case .invalidPayload:
            statusMessage = "激活响应校验失败，请重试"
            statusIsError = true
        case .rejected:
            statusMessage = "应用完整性校验失败，请从官方渠道重新安装。"
            statusIsError = true
        }
    }

    private func friendly(_ error: Error) -> String {
        if let api = error as? TraceintClient.ApiError { return api.message }
        if let license = error as? LicenseClientError { return license.errorDescription ?? "请求失败" }
        let value = error.localizedDescription
        return value.isEmpty ? String(describing: type(of: error)) : value
    }
}

extension Notification.Name {
    /// 会员凭证变化（激活成功 / 重新校验）。MainView 订阅它即可在激活后立刻收起门禁。
    static let goToLibraryLicenseChanged = Notification.Name("goToLibraryLicenseChanged")
}
