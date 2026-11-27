import Foundation
import Testing
@testable import DevToolsPlugin

@Test func parsesLsofOutputAndPsCommandsAccurately() {
    let lsofOutput = """
    p1234
    cnode
    Lalice
    n127.0.0.1:3000
    n[::1]:3000
    p5678
    cjava
    Lbob
    n*:8080
    """
    let psOutput = """
     1234 node /Users/alice/app/server.js --port 3000
     5678 /usr/bin/java -jar demo.jar
    """
    let psMap = PortScanner.parsePsOutput(psOutput)
    let items = PortScanner.parseLsofOutput(lsofOutput, psCommands: psMap)

    #expect(items.count == 3)
    #expect(items[0].port == 3000)
    #expect(items[0].pid == 1234)
    #expect(items[0].processName == "node")
    #expect(items[0].commandLine.contains("server.js"))
    #expect(items[2].port == 8080)
    #expect(items[2].bindAddress == "*")

    // 安全拦截 PID <= 1 与自身进程
    if case .failure(.protectedProcess) = PortScanner.terminateProcess(pid: 1) {
    } else {
        Issue.record("预期拒绝 PID 1")
    }
    let selfPID = ProcessInfo.processInfo.processIdentifier
    if case .failure(.protectedProcess) = PortScanner.terminateProcess(pid: selfPID) {
    } else {
        Issue.record("预期拒绝自身进程 PID")
    }
}

@Test func parsesLsofCwdOutputAndMatchesDevDirectoriesAccurately() throws {
    let lsofOutput = """
    p18920
    cnode
    Lalice
    n127.0.0.1:5173
    p39035
    cadb
    Lalice
    n127.0.0.1:5037
    p3707
    credis-server
    Lalice
    n127.0.0.1:6379
    p40100
    cjava
    Lalice
    n*:8080
    """
    let cwdOutput = """
    p18920
    fcwd
    n/Users/alice/huanwei/huanost/huanost-web/apps/student-pc
    p39035
    fcwd
    n/Users/alice/huanwei-backup/tools
    p3707
    fcwd
    n/opt/homebrew/var/db/redis
    p40100
    fcwd
    n/
    """
    let psOutput = """
     18920 node /Users/alice/huanwei/huanost/huanost-web/apps/student-pc/node_modules/.bin/vite --port 5173
     39035 adb -L tcp:5037 fork-server server --reply-fd 4
     3707 /opt/homebrew/opt/redis/bin/redis-server 127.0.0.1:6379
     40100 /usr/bin/java -jar /Users/alice/huanwei/backend/orders/target/orders.jar --server.port=8080
    """

    let cwds = PortScanner.parseLsofCwdOutput(cwdOutput)
    #expect(cwds[18920] == "/Users/alice/huanwei/huanost/huanost-web/apps/student-pc")
    #expect(cwds[3707] == "/opt/homebrew/var/db/redis")

    let items = PortScanner.parseLsofOutput(
        lsofOutput,
        psCommands: PortScanner.parsePsOutput(psOutput),
        workingDirectories: cwds
    )
    #expect(items.count == 4)

    let devDirs = [
        "/",
        NSHomeDirectory(),
        "/Users/alice/huanwei/",
        "/Users/alice/huanwei/huanost",
    ]
    let partition = PortDirectoryMatcher.partition(items, devDirectories: devDirs)

    // 18920 应命中更具体的嵌套根目录 /Users/alice/huanwei/huanost
    // 40100 虽 cwd 为 /，但命令行命中 /Users/alice/huanwei/backend/orders/target/orders.jar 并裁剪到项目目录
    // 39035 cwd 为 /Users/alice/huanwei-backup/tools（前缀相似但非子目录），不能误命中
    // 3707 为 redis，归入其他端口
    #expect(partition.devDirectoryItems.count == 2)
    #expect(partition.otherItems.count == 2)

    let firstDev = try #require(partition.devDirectoryItems.first { $0.item.pid == 18920 })
    #expect(firstDev.directoryMatch?.rootDirectory == "/Users/alice/huanwei/huanost")
    #expect(firstDev.directoryMatch?.projectLabel == "huanost-web/apps/student-pc")
    #expect(firstDev.directoryMatch?.basis == .workingDirectory)

    let secondDev = try #require(partition.devDirectoryItems.first { $0.item.pid == 40100 })
    #expect(secondDev.directoryMatch?.rootDirectory == "/Users/alice/huanwei")
    #expect(secondDev.directoryMatch?.matchedDirectory == "/Users/alice/huanwei/backend/orders")
    #expect(secondDev.directoryMatch?.projectLabel == "backend/orders")
    #expect(secondDev.directoryMatch?.basis == .commandLine)

    // 验证按 projectLabel 排序：backend/orders < huanost-web/apps/student-pc
    #expect(partition.devDirectoryItems.map(\.item.pid) == [40100, 18920])
    #expect(partition.otherItems.map(\.item.pid) == [39035, 3707])

    // 验证过宽路径拦截
    #expect(!PortDirectoryMatcher.isUsableRootDirectory("/"))
    #expect(!PortDirectoryMatcher.isUsableRootDirectory(PortDirectoryMatcher.normalizePath(NSHomeDirectory())))
}

@Test func devConvertersHandleTimestampJWTCodecHashAndDiff() throws {
    // 1. 时间戳
    let tsSec = try #require(DevConverters.parseTimestamp("1700000000"))
    #expect(tsSec.unitLabel == "秒 (s)")
    #expect(tsSec.milliseconds == 1_700_000_000_000)

    let tsMs = try #require(DevConverters.parseTimestamp("1700000000123"))
    #expect(tsMs.unitLabel == "毫秒 (ms)")
    #expect(tsMs.seconds == 1_700_000_000)

    // 2. JWT Base64URL 解码与过期判定
    // Header: {"alg":"HS256","typ":"JWT"} -> eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
    // Payload: {"sub":"42","exp":1700000000} -> eyJzdWIiOiI0MiIsImV4cCI6MTcwMDAwMDAwMH0
    let jwt = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsImV4cCI6MTcwMDAwMDAwMH0.sig"
    let decoded = try #require(DevConverters.decodeJWT(jwt, now: Date(timeIntervalSince1970: 1_700_003_600)))
    #expect(decoded.headerJSON.contains("HS256"))
    #expect(decoded.payloadJSON.contains("\"sub\" : \"42\""))
    #expect(decoded.isExpired == true)

    // 3. 编解码与摘要
    let encoded = DevConverters.base64Encode("饭碗 IronBowl")
    #expect(DevConverters.base64Decode(encoded) == "饭碗 IronBowl")
    let escaped = DevConverters.unicodeEscape("饭碗")
    #expect(escaped == "\\u996D\\u7897")
    #expect(DevConverters.unicodeUnescape(escaped) == "饭碗")
    #expect(DevConverters.sha256("abc").count == 64)
    #expect(DevConverters.md5("abc") == "900150983cd24fb0d6963f7d28e17f72")

    // 4. JSON 美化 Diff
    let diff = DevConverters.computeLineDiff(
        left: #"{"b":2,"a":1}"#,
        right: #"{"a":1,"b":3}"#,
        prettyJSON: true
    )
    #expect(diff.contains { $0.kind == .removed && $0.text.contains("2") })
    #expect(diff.contains { $0.kind == .added && $0.text.contains("3") })
}
