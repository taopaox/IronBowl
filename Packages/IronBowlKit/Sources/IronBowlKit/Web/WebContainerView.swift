import AppKit
import SwiftUI
import WebKit

/// 通用网页容器：自动处理显示/隐藏计数、休眠占位卡片与唤醒过渡快照。
public struct WebContainerView: View {
    let session: WebSession
    let manager: WebSessionManager
    let onClose: (() -> Void)?

    @State private var displayToken = UUID()

    public init(session: WebSession, manager: WebSessionManager, onClose: (() -> Void)? = nil) {
        self.session = session
        self.manager = manager
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            if session.state == .tombstoned {
                tombstoneView
            } else if let webView = session.webView {
                WebHostRepresentable(webView: webView)
                if session.isWakingUp, let snapshot = session.snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.isWakingUp)
        .onAppear {
            manager.attachDisplay(sessionID: session.id, token: displayToken)
        }
        .onChange(of: session.id) { oldID, newID in
            manager.detachDisplay(sessionID: oldID, token: displayToken)
            let nextToken = UUID()
            displayToken = nextToken
            manager.attachDisplay(sessionID: newID, token: nextToken)
        }
        .onDisappear {
            manager.detachDisplay(sessionID: session.id, token: displayToken)
        }
    }

    private var tombstoneView: some View {
        ZStack {
            if let snapshot = session.snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .opacity(0.22)
            } else {
                DS.canvas
            }

            DSCard(padding: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "moon.zzz")
                        .font(DS.font(26))
                        .foregroundStyle(DS.textSecondary)
                    Text("页面已休眠以节省内存")
                        .font(DS.pageTitle)
                    Text(session.currentURL)
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Button("重新唤醒") {
                            manager.attachDisplay(sessionID: session.id, token: displayToken)
                        }
                        .buttonStyle(.dsPrimary)

                        if let onClose {
                            Button("关闭网页", action: onClose)
                                .buttonStyle(.dsSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: DS.s(380))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.canvas)
    }
}

private struct WebHostRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebHostView {
        let host = WebHostView()
        attach(webView, to: host)
        return host
    }

    func updateNSView(_ hostView: WebHostView, context: Context) {
        attach(webView, to: hostView)
    }

    static func dismantleNSView(_ hostView: WebHostView, coordinator: ()) {
        // 仅当 WKWebView 仍归当前宿主所有时移除（避免 .id(fontScale) 重建时新视图刚抢走又被旧宿主拆掉）。
        if let webView = hostView.currentWebView, webView.superview === hostView {
            webView.removeFromSuperview()
        }
        hostView.currentWebView = nil
    }

    private func attach(_ target: WKWebView, to host: WebHostView) {
        guard host.currentWebView !== target || target.superview !== host else { return }
        if let old = host.currentWebView, old !== target, old.superview === host {
            old.removeFromSuperview()
        }
        if target.superview != nil, target.superview !== host {
            target.removeFromSuperview()
        }
        target.frame = host.bounds
        target.autoresizingMask = [.width, .height]
        host.addSubview(target)
        host.currentWebView = target
    }
}

private final class WebHostView: NSView {
    weak var currentWebView: WKWebView?
}
