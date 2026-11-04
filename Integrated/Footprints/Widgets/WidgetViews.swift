import SwiftUI
import WidgetKit

/// 羊皮纸配色，与主 App 地图画布一致（小组件独立编译，本地保留一份色板）。
private enum WidgetInk {
    static let text = Color(red: 0.24, green: 0.21, blue: 0.17)
    static let muted = Color(red: 0.52, green: 0.46, blue: 0.37)
    static let paper = Color(red: 0.97, green: 0.95, blue: 0.90)
    static let panel = Color(red: 0.99, green: 0.98, blue: 0.94)
    static let ochre = Color(red: 0.68, green: 0.37, blue: 0.17)
    static let line = Color(red: 0.63, green: 0.53, blue: 0.38).opacity(0.35)
    /// 与主 App 地图画布一致的羊皮纸底色，地图图片直接融入背景、无拼缝。
    static let canvas = Color(red: 0.92, green: 0.87, blue: 0.74)
}

struct FootprintMapWidgetView: View {
    let entry: FootprintWidgetEntry

    var body: some View {
        if let snapshot = entry.data.snapshot {
            ZStack(alignment: .leading) {
                WidgetInk.canvas
                if let map = entry.data.map {
                    // 完整显示地图：fit 缩放不裁剪，空白处与羊皮纸底色一致；
                    // 左侧留出统计面板的宽度，地图整体落在面板右侧不被遮挡。
                    Image(nsImage: map)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, 132)
                }
                HStack {
                    statsPanel(snapshot: snapshot)
                    Spacer(minLength: 0)
                }
            }
            .help(timeChainDescription)
            .accessibilityElement(children: .contain)
            .accessibilityValue(timeChainDescription)
        } else {
            emptyState
        }
    }

    private func statsPanel(snapshot: FootprintWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: snapshot.residentCityName == nil ? 7 : 4) {
            HStack(spacing: 3) {
                Text("节奏 · 足迹")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetInk.muted)
                Spacer(minLength: 0)
                Text(sourceDateLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(entry.data.readResult == "previous" ? WidgetInk.ochre : WidgetInk.muted)
                    .lineLimit(1)
                    .accessibilityLabel("资料更新时间：\(timestamp(entry.data.sourceModifiedAt))")
            }
            Text("\(snapshot.cities)")
                .font(.system(size: snapshot.residentCityName == nil ? 28 : 25, weight: .semibold, design: .rounded))
                .foregroundStyle(WidgetInk.text)
            + Text(" 城")
                .font(.system(size: 12))
                .foregroundStyle(WidgetInk.muted)
            if let city = snapshot.residentCityName {
                Label("常驻 · \(city)", systemImage: "house.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.17, green: 0.39, blue: 0.36))
                    .lineLimit(1)
                    .help("常驻城市：\(city)")
                    .accessibilityLabel("常驻城市：\(city)")
            }
            statRow(label: "国家/地区", value: "\(snapshot.countries)")
            statRow(label: "大洲", value: "\(snapshot.continents)")
            VStack(alignment: .leading, spacing: 3) {
                statRow(label: "中国城市", value: "\(snapshot.china)/\(snapshot.chinaTotal)")
                ProgressView(value: snapshot.chinaTotal > 0 ? Double(snapshot.china) / Double(snapshot.chinaTotal) : 0)
                    .progressViewStyle(.linear)
                    .tint(WidgetInk.ochre)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, snapshot.residentCityName == nil ? 10 : 8)
        .frame(width: 128)
        .background(WidgetInk.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WidgetInk.line, lineWidth: 1))
        .padding(.leading, 10)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(WidgetInk.muted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WidgetInk.text)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "map")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(WidgetInk.muted)
            Text("暂无可用快照")
                .font(.system(size: 12))
                .foregroundStyle(WidgetInk.muted)
            Text("打开搞节奏的足迹模块以同步地图与统计")
                .font(.system(size: 10))
                .foregroundStyle(WidgetInk.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WidgetInk.paper)
    }

    private var sourceDateLabel: String {
        guard let date = entry.data.sourceModifiedAt else { return "资料日期未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return "资料 \(formatter.string(from: date))"
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }

    private var timeChainDescription: String {
        let state = entry.data.readResult == "previous" ? "显示上一份完整快照" : "显示已发布的完整快照"
        return "\(state)\n资料更新：\(timestamp(entry.data.sourceModifiedAt))\n快照发布：\(timestamp(entry.data.publishedAt))\n系统请求：\(timestamp(entry.data.requestedAt))\n组件读取：\(timestamp(entry.data.readAt))"
    }
}
