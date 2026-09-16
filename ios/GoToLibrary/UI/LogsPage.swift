// 对应 Android 侧 MainActivity 的运行记录面板（logText + 复制 / 清空 + 日志变更广播）。
import SwiftUI
import Combine
import UIKit

@MainActor
struct LogsPage: View {

    @ObservedObject private var themeStore = ThemeStore.shared

    private var colors: ThemeColors { themeStore.colors }

    /// AppConfig 里日志是最新在前（addLog 插到数组头部），这里倒序成时间正序展示，
    /// 最新一条在底部，配合"订阅变更 → 自动滚到底部"。
    @State private var lines: [String] = []

    init() {}

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                SectionBar("运行记录")
                Spacer()
                Button("复制全部") { copyAll() }
                    .buttonStyle(GlassSecondaryButtonStyle())
                    .disabled(lines.isEmpty)
                Button("清空") { AppConfig.clearLogs() }
                    .buttonStyle(GlassSecondaryButtonStyle())
                    .disabled(lines.isEmpty)
            }
            .padding(.horizontal, 18)

            if lines.isEmpty {
                GlassCard {
                    Text("暂无运行记录")
                        .font(.footnote)
                        .foregroundColor(colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 18)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(lines.indices, id: \.self) { index in
                                Text(lines[index])
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundColor(colors.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                    }
                    .glassPanel()
                    .padding(.horizontal, 18)
                    .onAppear { scrollToBottom(proxy, animated: false) }
                    .onChange(of: lines.count) { _ in scrollToBottom(proxy, animated: true) }
                }
            }
        }
        .padding(.top, 8)
        .onAppear { reload() }
        // addLog / clearLogs 都会广播这个通知，日志页据此刷新；
        // 抢座任务在后台线程写日志也能立刻反映到界面。
        .onReceive(NotificationCenter.default.publisher(for: .goToLibraryLogsChanged)) { _ in
            reload()
        }
    }

    private func reload() {
        let text = AppConfig.logsText()
        guard text != "暂无运行记录" else {
            lines = []
            return
        }
        lines = Array(text.split(separator: "\n").map(String.init).reversed())
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = lines.indices.last else { return }
        if animated {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private func copyAll() {
        UIPasteboard.general.string = AppConfig.logsText()
    }
}
