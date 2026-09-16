// 对应 Android 侧 MainActivity 的预约页（任务模式 / 微信登录 / 阅览室 / 优先座位 / 预约参数）。
import SwiftUI
import UIKit

@MainActor
struct BookingPage: View {

    @ObservedObject private var runner = ReservationRunner.shared
    @ObservedObject private var themeStore = ThemeStore.shared

    private var colors: ThemeColors { themeStore.colors }

    @State private var mode: String = AppConfig.mode()
    @State private var tomorrowTime: String = AppConfig.tomorrowTime()
    @State private var authURL: String = ""
    @State private var rooms: [TraceintClient.Room] = []
    @State private var roomIndex: Int = 0
    @State private var selectedSeats: [String] = AppConfig.selectedSeats()
    @State private var loggedIn: Bool = AppConfig.isLoggedIn()
    @State private var showSeatPicker = false

    @State private var parsing = false
    @State private var loadingRooms = false
    @State private var errorText: String?
    @State private var noticeText: String?

    @State private var captchaAutoSolve: Bool = AppConfig.captchaAutoSolve()
    @State private var venueAutoWait: Bool = AppConfig.venueAutoWait()
    @State private var prefetchCaptcha: Bool = AppConfig.prefetchCaptcha()
    @State private var queueAdvanceAuto: Bool = AppConfig.queueAdvanceAuto()
    @State private var queueAdvanceMsText: String = String(AppConfig.queueAdvanceMs())
    @State private var queueBeforeText: String = String(AppConfig.queueBeforeInterval())
    @State private var queueAfterText: String = String(AppConfig.queueAfterInterval())

    /// 捡漏开关两个平台都只有 getter（Android 端同样没有 setter），只做只读展示。
    private var autoGrabOther: Bool { AppConfig.autoGrabOther() }

    /// 契约里 venueAutoWait / prefetchCaptcha / queueAdvanceAuto / 三个间隔值都只有 getter，
    /// 没有独立的 setXxx，所以按契约公开的 `AppConfig.KEY_*` 键名直接写入同一个
    /// UserDefaults suite —— AppConfig 的读写本来就落在这个 suite 上，语义一致。
    private static let prefs = UserDefaults(suiteName: AppConfig.prefsSuiteName) ?? .standard

    init() {}

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modeCard.panelEntrance(0)
                loginCard.panelEntrance(1)
                roomCard.panelEntrance(2)
                seatCard.panelEntrance(3)
                parameterCard.panelEntrance(4)
                actionCard.panelEntrance(5)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showSeatPicker) {
            SeatPickerView(roomId: AppConfig.roomId()) { seats in
                // 面板只回传结果，落盘必须在这里做：不写盘的话 AppConfig.selectedSeats()
                // 永远是空数组，orderCandidates 会退化成"不限座位、随机挑"，用户选的座位等于没配。
                AppConfig.saveSelectedSeats(seats)
                selectedSeats = seats
            }
        }
        // 首页的"预约明日座位"快捷入口会先改 AppConfig 再切页，而本页的 @State 只在
        // 构造时读一次配置，所以每次出现都重新同步一遍。
        .onAppear { syncFromConfig() }
        .task {
            if AppConfig.isLoggedIn(), rooms.isEmpty {
                await refreshRooms()
            }
        }
    }

    // MARK: - 任务模式

    private var modeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("任务模式")
                Picker("任务模式", selection: $mode) {
                    Text("实时捡漏").tag(AppConfig.modeRealtime)
                    Text("明日预约").tag(AppConfig.modeTomorrow)
                }
                .pickerStyle(.segmented)
                .disabled(runner.running)
                .onChange(of: mode) { value in
                    AppConfig.setMode(value)
                }

                if mode == AppConfig.modeTomorrow {
                    HStack {
                        Text("开始监控时间")
                            .font(.footnote)
                            .foregroundColor(colors.secondaryText)
                        Spacer()
                        TextField("20:00:00", text: $tomorrowTime)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 118)
                            .disabled(runner.running)
                    }
                    Text("到点后自动进入排队通道，以低频监控明日空位并串行尝试，成功或触发风控会自动停止。")
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 微信登录

    private var loginCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("微信登录")
                HStack(spacing: 8) {
                    PulseDot(active: loggedIn, color: loggedIn ? colors.primary : colors.navIdle)
                    Text(loggedIn ? "微信登录有效" : "尚未登录")
                        .font(.subheadline)
                        .foregroundColor(loggedIn ? colors.ink : colors.danger)
                }
                // iOS 无法截获微信授权回调：OAuth 在微信内部完成，系统不会把跳转地址回传给
                // 本应用（ASWebAuthenticationSession / SFSafariViewController 同样拿不到，
                // 微信并不回调自定义 scheme）。所以流程固定为三步，只能靠手工把链接带回来。
                Text("复制链接后在微信内完成登录，再复制当前页面地址粘贴回来。")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("复制登录链接") { copyLoginLink() }
                        .buttonStyle(GlassSecondaryButtonStyle())
                        .disabled(runner.running)
                    Button("从剪贴板读取") { readClipboardLink() }
                        .buttonStyle(GlassSecondaryButtonStyle())
                        .disabled(runner.running)
                }

                Button {
                    if let url = URL(string: BuildConfig.tutorialURL) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("📖 查看微信绑定教程").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassSecondaryButtonStyle())

                TextField("在微信登录后，粘贴当前页面地址", text: $authURL, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(runner.running)

                Button {
                    parseLogin()
                } label: {
                    Text(parsing ? "正在解析登录…" : "解析登录并获取阅览室")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassPrimaryButtonStyle())
                .disabled(parsing || runner.running)

                Button {
                    clearLogin()
                } label: {
                    Text("退出登录").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassSecondaryButtonStyle())
                .disabled(!loggedIn || runner.running)
            }
        }
    }

    // MARK: - 阅览室

    private var currentRoom: TraceintClient.Room? {
        rooms.indices.contains(roomIndex) ? rooms[roomIndex] : nil
    }

    private var roomCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionBar("阅览室")
                    Spacer()
                    Button(loadingRooms ? "读取中" : "刷新") {
                        Task { await refreshRooms() }
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                    .disabled(!loggedIn || loadingRooms || runner.running)
                }
                if rooms.isEmpty {
                    Text(loggedIn ? "正在读取阅览室…" : "请先完成微信登录")
                        .font(.footnote)
                        .foregroundColor(colors.secondaryText)
                } else {
                    Picker("阅览室", selection: $roomIndex) {
                        ForEach(rooms.indices, id: \.self) { index in
                            Text(rooms[index].name).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(runner.running)
                    .onChange(of: roomIndex) { _ in applyRoomSelection() }

                    if let room = currentRoom {
                        Text(room.open ? "余座 \(room.available)" : "余座 \(room.available) · 场馆未开放")
                            .font(.caption)
                            .foregroundColor(colors.secondaryText)
                    }
                }
            }
        }
    }

    // MARK: - 优先座位

    private var seatSummary: String {
        guard !selectedSeats.isEmpty else { return "未限制座位，将选择任意空位" }
        let shown = selectedSeats.prefix(8).joined(separator: "、")
        return selectedSeats.count > 8 ? "优先座位：\(shown) 等 \(selectedSeats.count) 个" : "优先座位：\(shown)"
    }

    private var seatCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("选择优先座位")
                Text(seatSummary)
                    .font(.footnote)
                    .foregroundColor(colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        showSeatPicker = true
                    } label: {
                        Text("选择优先座位").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPrimaryButtonStyle())
                    .disabled(!loggedIn || AppConfig.roomId() == 0 || runner.running)
                    Button {
                        AppConfig.saveSelectedSeats([])
                        selectedSeats = []
                        noticeText = "已清空优先座位"
                    } label: {
                        Text("清空")
                    }
                    .buttonStyle(GlassSecondaryButtonStyle())
                    .disabled(selectedSeats.isEmpty || runner.running)
                }
            }
        }
    }

    // MARK: - 预约参数

    private var parameterCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionBar("预约配置")

                Toggle("自动识别验证码", isOn: $captchaAutoSolve)
                    .tint(colors.primary)
                Text("关闭后以空验证码提交，服务器要求验证码时跳过该座位")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)

                HStack {
                    Text("捡漏其他空位")
                        .font(.subheadline)
                        .foregroundColor(colors.ink)
                    Spacer()
                    Text(autoGrabOther ? "已开启" : "已关闭")
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                }
                Text("指定座位全部失效后自动尝试其它空闲座位（只读，需在官方页面调整）。")
                    .font(.caption)
                    .foregroundColor(colors.secondaryText)

                Toggle("场馆未开放自动等待", isOn: $venueAutoWait)
                    .tint(colors.primary)
                Toggle("预先获取验证码", isOn: $prefetchCaptcha)
                    .tint(colors.primary)
                Toggle("排队提前量自动校时", isOn: $queueAdvanceAuto)
                    .tint(colors.primary)

                numberField("提前量毫秒", text: $queueAdvanceMsText, enabled: !queueAdvanceAuto)
                numberField("入队前间隔毫秒", text: $queueBeforeText, enabled: true)
                numberField("入队后间隔毫秒", text: $queueAfterText, enabled: true)
            }
            .disabled(runner.running)
        }
    }

    private func numberField(_ title: String, text: Binding<String>, enabled: Bool) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundColor(colors.secondaryText)
            Spacer()
            TextField("", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    // MARK: - 保存与启动

    private var actionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionBar("任务操作")
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(colors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let noticeText {
                    Text(noticeText)
                        .font(.caption)
                        .foregroundColor(colors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if runner.running {
                    Button {
                        runner.stop()
                    } label: {
                        Text("停止").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPrimaryButtonStyle())
                } else {
                    Button {
                        // 先把界面上的配置落盘再启动：ReservationRunner 读的是 AppConfig，
                        // 顺序反了会用上一份配置下发任务。
                        if saveConfig() {
                            Task { await runner.start() }
                        }
                    } label: {
                        Text("开始任务").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPrimaryButtonStyle())
                }
                Button {
                    _ = saveConfig()
                } label: {
                    Text("保存配置").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassSecondaryButtonStyle())
            }
        }
    }

    // MARK: - 登录流程

    private func makeClient() -> TraceintClient {
        TraceintClient(cookie: AppConfig.cookie()) { refreshed in
            _ = AppConfig.setCookie(refreshed)
        }
    }

    private func friendly(_ error: Error) -> String {
        if let api = error as? TraceintClient.ApiError { return api.message }
        let value = error.localizedDescription
        return value.isEmpty ? String(describing: type(of: error)) : value
    }

    private func copyLoginLink() {
        UIPasteboard.general.string = TraceintClient.loginURL
        AppConfig.addLog("已复制微信登录链接，请在微信内完成登录")
        noticeText = "登录链接已复制，请在微信中打开"
        errorText = nil
    }

    private func readClipboardLink() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "剪贴板里没有可用的链接"
            return
        }
        authURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
    }

    private func parseLogin() {
        let callback = authURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callback.isEmpty else {
            errorText = "请粘贴微信登录后的完整页面地址"
            return
        }
        parsing = true
        errorText = nil
        noticeText = nil
        Task {
            do {
                let cookie = try await TraceintClient.exchangeCallbackForCookie(callback)
                guard AppConfig.setCookie(cookie) else {
                    throw TraceintClient.ApiError(message: "本机加密存储初始化失败")
                }
                let fetched = try await makeClient().fetchRooms()
                guard !fetched.isEmpty else {
                    throw TraceintClient.ApiError(message: "登录会话没有返回阅览室")
                }
                AppConfig.addLog("微信登录成功（Cookie：\(TraceintClient.cookieNames(cookie))），"
                    + "已读取 \(fetched.count) 个阅览室")
                rooms = fetched
                if let index = fetched.firstIndex(where: { $0.id == AppConfig.roomId() }) {
                    roomIndex = index
                }
                applyRoomSelection()
                loggedIn = true
                authURL = ""
                noticeText = "登录成功，欢迎回来"
                errorText = nil
            } catch {
                let message = friendly(error)
                AppConfig.addLog("登录验证失败：" + message)
                errorText = "登录验证失败：" + message
            }
            parsing = false
        }
    }

    private func clearLogin() {
        // 对齐 Android clearLocalSession：Cookie、阅览室、已选座位一起清，
        // 否则换账号后会用上一个账号的座位配置直接开跑。
        AppConfig.clearCookie()
        AppConfig.setRoomId(0)
        AppConfig.setRoomName("")
        AppConfig.saveSelectedSeats([])
        rooms = []
        roomIndex = 0
        selectedSeats = []
        loggedIn = false
        authURL = ""
        AppConfig.addLog("已清除本机登录会话")
        noticeText = "已清除登录"
        errorText = nil
    }

    private func refreshRooms() async {
        guard AppConfig.isLoggedIn() else {
            errorText = "请先微信登录"
            return
        }
        loadingRooms = true
        do {
            let fetched = try await makeClient().fetchRooms()
            guard !fetched.isEmpty else {
                throw TraceintClient.ApiError(message: "账号没有返回阅览室")
            }
            rooms = fetched
            if let index = fetched.firstIndex(where: { $0.id == AppConfig.roomId() }) {
                roomIndex = index
            }
            applyRoomSelection()
            noticeText = "已读取 \(fetched.count) 个阅览室"
            errorText = nil
        } catch {
            let message = friendly(error)
            if TraceintClient.isSessionExpired(message) {
                AppConfig.clearCookie()
                rooms = []
                loggedIn = false
                AppConfig.addLog("登录会话已失效，请重新微信登录")
                errorText = "登录已失效，请重新微信登录"
            } else {
                errorText = "读取失败：" + message
            }
        }
        loadingRooms = false
    }

    // MARK: - 配置读写

    private func syncFromConfig() {
        mode = AppConfig.mode()
        tomorrowTime = AppConfig.tomorrowTime()
        selectedSeats = AppConfig.selectedSeats()
        loggedIn = AppConfig.isLoggedIn()
        captchaAutoSolve = AppConfig.captchaAutoSolve()
        venueAutoWait = AppConfig.venueAutoWait()
        prefetchCaptcha = AppConfig.prefetchCaptcha()
        queueAdvanceAuto = AppConfig.queueAdvanceAuto()
        queueAdvanceMsText = String(AppConfig.queueAdvanceMs())
        queueBeforeText = String(AppConfig.queueBeforeInterval())
        queueAfterText = String(AppConfig.queueAfterInterval())
        if let index = rooms.firstIndex(where: { $0.id == AppConfig.roomId() }) {
            roomIndex = index
        }
    }

    private func applyRoomSelection() {
        guard let room = currentRoom else { return }
        AppConfig.setRoomId(room.id)
        AppConfig.setRoomName(room.name)
    }

    private static func isValidTime(_ value: String) -> Bool {
        value.range(of: "^([01]\\d|2[0-3]):[0-5]\\d(:[0-5]\\d)?$", options: .regularExpression) != nil
    }

    /// 返回 false 表示校验不通过，调用方不要继续启动任务。
    @discardableResult
    private func saveConfig() -> Bool {
        var time = tomorrowTime.trimmingCharacters(in: .whitespaces)
        if time.isEmpty { time = "20:00:00" }
        // Android 允许只填 HH:mm，落盘前统一补成 HH:mm:ss。
        if time.count == 5 { time += ":00" }
        if mode == AppConfig.modeTomorrow, !BookingPage.isValidTime(time) {
            errorText = "请输入 HH:mm 或 HH:mm:ss"
            return false
        }
        tomorrowTime = time

        AppConfig.setMode(mode)
        AppConfig.setTomorrowTime(time)
        applyRoomSelection()
        AppConfig.setCaptchaAutoSolve(captchaAutoSolve)
        BookingPage.prefs.set(venueAutoWait, forKey: AppConfig.KEY_VENUE_AUTO_WAIT)
        BookingPage.prefs.set(prefetchCaptcha, forKey: AppConfig.KEY_PREFETCH_CAPTCHA)
        BookingPage.prefs.set(queueAdvanceAuto, forKey: AppConfig.KEY_QUEUE_ADVANCE_AUTO)
        BookingPage.prefs.set(Int(queueAdvanceMsText) ?? AppConfig.queueAdvanceMs(),
                              forKey: AppConfig.KEY_QUEUE_ADVANCE_MS)
        BookingPage.prefs.set(Int(queueBeforeText) ?? AppConfig.queueBeforeInterval(),
                              forKey: AppConfig.KEY_QUEUE_BEFORE_INTERVAL)
        BookingPage.prefs.set(Int(queueAfterText) ?? AppConfig.queueAfterInterval(),
                              forKey: AppConfig.KEY_QUEUE_AFTER_INTERVAL)

        let seats = AppConfig.selectedSeats()
        let seatText = seats.isEmpty ? "不限座位" : seats.joined(separator: "、")
        let modeText = mode == AppConfig.modeTomorrow ? "明日预约 \(time)" : "实时捡漏"
        AppConfig.addLog("预约配置已保存：\(modeText)，\(AppConfig.roomName())，\(seatText)")
        errorText = nil
        noticeText = "配置已保存"
        return true
    }
}
