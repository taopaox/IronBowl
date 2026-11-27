import Foundation
import Testing
@testable import IronBowlKit

struct MeetingScheduleTests {
    @Test("提取入会链接优先识别视频会议域名")
    func extractMeetingURLPrefersConferencingDomains() {
        let url = MeetingEvent.extractMeetingURL(from: [
            "会议室 A302",
            "参考文档 https://example.com/spec 请提前查看，入会链接 https://vc.feishu.cn/j/123456789",
        ])
        #expect(url?.absoluteString == "https://vc.feishu.cn/j/123456789")
    }

    @Test("会议时长按 0.5h 步长折算为建议日报工时")
    func suggestedLogHoursRoundsToHalfHour() {
        let base = Date(timeIntervalSince1970: 1_764_200_000)
        let shortMeeting = MeetingEvent(
            id: "1",
            title: "晨会",
            startDate: base,
            endDate: base.addingTimeInterval(15 * 60)
        )
        #expect(shortMeeting.suggestedLogHours == 0.5)

        let mediumMeeting = MeetingEvent(
            id: "2",
            title: "需求评审",
            startDate: base,
            endDate: base.addingTimeInterval(80 * 60)
        )
        #expect(mediumMeeting.suggestedLogHours == 1.5)

        let allDay = MeetingEvent(
            id: "3",
            title: "封版日",
            startDate: base,
            endDate: base.addingTimeInterval(24 * 3600),
            isAllDay: true
        )
        #expect(allDay.suggestedLogHours == 1.0)
    }

    @Test("跨源重复会议去重优先保留含入会链接的条目并过滤全天事件")
    func deduplicateAndSortBehavior() {
        let base = Date(timeIntervalSince1970: 1_764_200_000)
        let withoutURL = MeetingEvent(
            id: "sys.1",
            title: "周例会",
            startDate: base.addingTimeInterval(3600),
            endDate: base.addingTimeInterval(5400),
            source: .systemCalendar
        )
        let withURL = MeetingEvent(
            id: "dt.1",
            title: "周例会",
            startDate: base.addingTimeInterval(3600),
            endDate: base.addingTimeInterval(5400),
            meetingURL: URL(string: "https://meeting.dingtalk.com/j/abc"),
            source: .dingtalk
        )
        let allDay = MeetingEvent(
            id: "sys.all",
            title: "发版窗口",
            startDate: base,
            endDate: base.addingTimeInterval(86400),
            isAllDay: true
        )
        let filtered = MeetingEvent.deduplicateAndSort([withoutURL, withURL, allDay], hideAllDay: true)
        #expect(filtered.count == 1)
        #expect(filtered[0].id == "dt.1")
        #expect(filtered[0].meetingURL != nil)

        let keptAllDay = MeetingEvent.deduplicateAndSort([withoutURL, allDay], hideAllDay: false)
        #expect(keptAllDay.count == 2)
        #expect(keptAllDay[0].isAllDay == true)
    }

    @Test("解析钉钉 dws calendar JSON 输出")
    func parseDingTalkJSON() throws {
        let json = """
        {
          "events": [
            {
              "id": "evt-001",
              "summary": "版本评审会",
              "isAllDay": false,
              "start": { "dateTime": "2026-11-27T14:00:00+08:00" },
              "end": { "dateTime": "2026-11-27T15:00:00+08:00" },
              "location": { "displayName": "线上会议室" },
              "onlineMeetingInfo": { "url": "https://meeting.dingtalk.com/j/998877" }
            },
            {
              "id": "evt-002",
              "summary": "公司年会",
              "isAllDay": true,
              "start": { "date": "2026-12-30" },
              "end": { "date": "2026-12-31" }
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let events = MeetingEvent.parseDingTalkEventsJSON(data)
        #expect(events.count == 2)
        #expect(events[0].title == "版本评审会")
        #expect(events[0].meetingURL?.absoluteString == "https://meeting.dingtalk.com/j/998877")
        #expect(events[0].suggestedLogHours == 1.0)
        #expect(events[1].isAllDay == true)
    }

    @MainActor
    @Test("查找当前或即将开始的下一场会议")
    func nextUpcomingMeetingSelection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "ironbowl-meeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try AppDatabase(url: tempDir.appending(path: "test.sqlite"), migrations: [])
        let settings = SettingsStore(database: db)
        let service = MeetingScheduleService(settings: settings)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = today.addingTimeInterval(10 * 3600) // 10:00

        // 验证无启用源时不拉取、为空
        #expect(service.nextUpcomingMeeting(now: now) == nil)
    }
}
