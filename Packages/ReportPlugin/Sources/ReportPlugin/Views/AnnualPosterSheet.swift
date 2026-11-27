import AppKit
import IronBowlKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnualPosterSheet: View {
    let data: AnnualPosterData
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("牛马年度报告")
                    .font(DS.pageTitle)
                Spacer()
                Button("复制图片") { copyPosterImage() }
                    .buttonStyle(.dsSecondary)
                Button("保存 PNG…") { exportPosterPNG() }
                    .buttonStyle(.dsPrimary)
                Button("关闭") { dismiss() }
                    .buttonStyle(.dsGhost)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().overlay(DS.border)

            ScrollView {
                VStack(spacing: 12) {
                    if let feedback {
                        DSBanner(.success, feedback)
                            .frame(width: 480)
                    }
                    AnnualPosterCard(data: data)
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(DS.groupBackground)
        }
        .frame(width: 580, height: 680)
    }

    @MainActor
    private func renderPosterImage() -> NSImage? {
        let renderer = ImageRenderer(content: AnnualPosterCard(data: data).environment(\.colorScheme, .light))
        renderer.scale = 2.0
        return renderer.nsImage
    }

    @MainActor
    private func copyPosterImage() {
        guard let image = renderPosterImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        feedback = "已复制高清报告卡片到剪贴板"
    }

    @MainActor
    private func exportPosterPNG() {
        guard let image = renderPosterImage(),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(data.title).png"
        if panel.runModal() == .OK, let url = panel.url {
            try? pngData.write(to: url, options: .atomic)
            feedback = "已保存至 \(url.lastPathComponent)"
        }
    }
}

private struct AnnualPosterCard: View {
    let data: AnnualPosterData

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("饭碗 · \(data.title)")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Color(nsColor: .init(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)))
                    Text("\(data.userName) · \(data.periodRange)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(data.badgeTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .init(srgbRed: 0.96, green: 0.62, blue: 0.14, alpha: 1)), in: .capsule)
            }

            Text(data.badgeSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                posterMetric("累计填报工时", "\(WorkCalendar.hoursText(data.totalHours))h", "正常 \(WorkCalendar.hoursText(data.normalHours))h · 加班 \(WorkCalendar.hoursText(data.overtimeHours))h")
                posterMetric("出勤天数", "\(data.loggedDaysCount)/\(data.expectedWorkdaysCount) 天", data.overtimeDaysCount > 0 ? "加班 \(data.overtimeDaysCount) 天" : "准点下班典范")
                posterMetric("代码提交", "\(data.commitCount) 次", "+\(data.addedLines) / -\(data.deletedLines) 行")
                posterMetric("平均上班", data.averageClockIn ?? "—", data.latestOffWork.map { "最晚 \($0)" } ?? (data.busiestMonth.map { "最忙 \($0)" } ?? "暂无打卡极值"))
            }

            if !data.topProjects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("主力投入项目")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(data.topProjects) { proj in
                        HStack(spacing: 8) {
                            Text(proj.projectName)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(WorkCalendar.hoursText(proj.hours))h · \(Int((proj.share * 100).rounded()))%")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.035), in: .rect(cornerRadius: 10))
            }

            HStack {
                Text(AppBrand.slogan)
                    .font(.system(size: 11.5, design: .serif))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("IronBowl")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(.white, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        }
    }

    private func posterMetric(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundStyle(Color(nsColor: .init(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)))
            Text(detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.035), in: .rect(cornerRadius: 10))
    }
}
