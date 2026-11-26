import Testing
@testable import ZentaoLogPlugin

@Test func matchesDailyReportIntentsAndAvoidsCodeQuestions() {
    #expect(ZentaoChatHandler.match("生成今日日报") == .generateDaily(dayOffset: 0))
    #expect(ZentaoChatHandler.match("帮我生成今天的禅道日志") == .generateDaily(dayOffset: 0))
    #expect(ZentaoChatHandler.match("生成昨日日报") == .generateDaily(dayOffset: -1))
    #expect(ZentaoChatHandler.match("查看今日日报") == .showDaily(dayOffset: 0))
    #expect(ZentaoChatHandler.match("今日日报") == .generateDaily(dayOffset: 0))
    #expect(ZentaoChatHandler.match("记日志：下午和产品对需求 2 小时") == .quickLog(sentence: "下午和产品对需求 2 小时"))

    // 不应拦截代码开发或排错提问
    #expect(ZentaoChatHandler.match("修复日报页面的 bug") == nil)
    #expect(ZentaoChatHandler.match("解释一下 LogModel.swift 是怎么生成日报的") == nil)
    #expect(ZentaoChatHandler.match("为什么生成日报代码里要过滤仓库") == nil)
    #expect(ZentaoChatHandler.match("帮我写一个 Swift 函数") == nil)
}
