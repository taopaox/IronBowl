import Foundation
import Testing
@testable import ZentaoLogPlugin

/// 本机集成测试：IRONBOWL_IT=1 swift test --filter LocalScan
@Test(.enabled(if: ProcessInfo.processInfo.environment["IRONBOWL_IT"] == "1"))
func localScanToday() async throws {
    let repos = GitScanner.discoverRepos(root: "/Users/yxhc/huanwei", depth: 2)
    let email = await GitScanner.globalEmail() ?? ""
    let start = Date()
    let acts = await GitScanner.activity(repos: repos, authorEmail: email, day: Date())
    print("repos=\(repos.count) email=\(email) took=\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    for a in acts { print("  \(a.repoName): \(a.commits.count) commits, \(a.lines) lines, weight \(String(format: "%.1f", a.weight))") }
    let hours = DraftGenerator.allocate(total: 8, weights: acts.map(\.weight))
    print("  hours: \(hours)")
    for a in acts { print("  fallback[\(a.repoName)]:\n\(DraftGenerator.fallbackWork(a))") }
    #expect(!repos.isEmpty)
}
