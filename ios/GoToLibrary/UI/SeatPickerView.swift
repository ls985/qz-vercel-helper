// 对应 Android 侧 MainActivity.showSeatPicker（"选择优先座位"多选弹窗）。
import Foundation
import SwiftUI

@MainActor
struct SeatPickerView: View {

    @ObservedObject private var themeStore = ThemeStore.shared

    private var colors: ThemeColors { themeStore.colors }

    let roomId: Int
    private let onConfirm: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var seats: [TraceintClient.Seat] = []
    /// 与 AppConfig.selectedSeats() 保持一致：Android 存的是座位名，两端都按 name 匹配。
    @State private var selected: Set<String> = Set(AppConfig.selectedSeats())
    @State private var loading = true
    @State private var errorText: String?

    init(roomId: Int, onConfirm: @escaping ([String]) -> Void) {
        self.roomId = roomId
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(colors.appBackground.ignoresSafeArea())
        .task { await loadSeats() }
    }

    // MARK: - 结构

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }
                .buttonStyle(GlassSecondaryButtonStyle())
            Spacer()
            Text("选择优先座位")
                .font(.headline)
                .foregroundColor(colors.ink)
            Spacer()
            Button("清空") { selected.removeAll() }
                .buttonStyle(GlassSecondaryButtonStyle())
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack {
                Spacer()
                Text("正在读取座位…")
                    .font(.footnote)
                    .foregroundColor(colors.secondaryText)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let errorText {
            VStack(spacing: 12) {
                Spacer()
                Text(errorText)
                    .font(.footnote)
                    .foregroundColor(colors.danger)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await loadSeats() } }
                    .buttonStyle(GlassSecondaryButtonStyle())
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
        } else if seats.isEmpty {
            VStack {
                Spacer()
                Text("当前阅览室没有可选座位")
                    .font(.footnote)
                    .foregroundColor(colors.secondaryText)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    ForEach(seats, id: \.key) { seat in
                        seatCell(seat)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("已选 \(selected.count) 个")
                .font(.footnote)
                .foregroundColor(colors.secondaryText)
            Spacer()
            Button("保存") {
                onConfirm(orderedSelection)
                dismiss()
            }
            .buttonStyle(GlassPrimaryButtonStyle())
            .disabled(loading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 座位格

    /// 三态：已选（写入 AppConfig 的那批）/ 可选（上游判定空闲）/ 不可用（其余）。
    private func seatCell(_ seat: TraceintClient.Seat) -> some View {
        let isSelected = selected.contains(seat.name)
        let selectable = TraceintClient.isFree(seat)
        return Button {
            toggle(seat, selectable: selectable)
        } label: {
            VStack(spacing: 4) {
                Text(seat.name)
                    .font(.footnote)
                    .foregroundColor(isSelected ? colors.appBackground : colors.ink)
                    .lineLimit(1)
                Text(isSelected ? "已选" : (selectable ? "可选" : "不可用"))
                    .font(.caption2)
                    .foregroundColor(isSelected ? colors.appBackground : colors.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? colors.primary : colors.surface.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? colors.primary : colors.secondaryText.opacity(0.35), lineWidth: 1)
            )
            .opacity(selectable || isSelected ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!selectable && !isSelected)
    }

    private func toggle(_ seat: TraceintClient.Seat, selectable: Bool) {
        if selected.contains(seat.name) {
            selected.remove(seat.name)
            return
        }
        guard selectable else { return }
        selected.insert(seat.name)
    }

    /// 按网格展示顺序输出，保证落盘顺序稳定（顺序会影响候选座位的尝试次序）。
    private var orderedSelection: [String] {
        seats.filter { selected.contains($0.name) }.map(\.name)
    }

    // MARK: - 数据

    private func loadSeats() async {
        loading = true
        errorText = nil
        do {
            let client = TraceintClient(cookie: AppConfig.cookie()) { refreshed in
                _ = AppConfig.setCookie(refreshed)
            }
            let fetched = try await client.fetchSeats(roomId: roomId)
            // 只保留可预约座位（type == 1）且名/键齐全的，排序对齐 Android compareSeatNames。
            seats = fetched
                .filter {
                    $0.type == 1
                        && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty
                        && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch is CancellationError {
            // 面板被关闭时取消，不算错误。
        } catch {
            let message = error.localizedDescription
            errorText = "座位读取失败：" + message
            AppConfig.addLog("座位读取失败：" + message)
        }
        loading = false
    }
}
