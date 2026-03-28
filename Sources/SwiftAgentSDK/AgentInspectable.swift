import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - .agentInspectable() root modifier

struct AgentInspectableModifier: ViewModifier {
    let viewStore: AgentViewStore

    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(AgentViewFrameKey.self) { anchors in
                // This closure re-runs whenever any anchor preference changes.
                FrameResolver(anchors: anchors, viewStore: viewStore)
            }
            .background(PlatformViewBridge(viewStore: viewStore))
            .onAppear {
                AgentViewStore.active = viewStore
            }
    }
}

/// Resolves anchor preferences to CGRects using a GeometryReader.
/// Extracted into its own View so SwiftUI re-evaluates on preference changes.
private struct FrameResolver: View {
    let anchors: [String: Anchor<CGRect>]
    let viewStore: AgentViewStore

    var body: some View {
        GeometryReader { geometry in
            let _ = {
                var resolved: [String: CGRect] = [:]
                for (id, anchor) in anchors {
                    resolved[id] = geometry[anchor]
                }
                viewStore.frames = resolved
            }()
            Color.clear
        }
    }
}

// MARK: - Platform View Bridge

#if canImport(AppKit)
struct PlatformViewBridge: NSViewRepresentable {
    let viewStore: AgentViewStore

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window, let contentView = window.contentView {
                viewStore.rootView = contentView
                let bridgeFrameInRoot = nsView.superview?.convert(nsView.frame, to: contentView) ?? nsView.frame
                viewStore.contentOffset = bridgeFrameInRoot.origin
            }
        }
    }
}
#elseif canImport(UIKit)
struct PlatformViewBridge: UIViewRepresentable {
    let viewStore: AgentViewStore

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let window = uiView.window {
                let root = window.rootViewController?.view ?? window
                viewStore.rootView = root
                // Capture the offset from rootView to SwiftUI content
                let bridgeFrameInRoot = uiView.superview?.convert(uiView.frame, to: root) ?? uiView.frame
                viewStore.contentOffset = bridgeFrameInRoot.origin
            }
        }
    }
}
#endif

// MARK: - Public API

extension View {
    /// Install view inspection at the root of your view hierarchy.
    /// This enables the POST /view protocol for tree, screenshot, get/set/call.
    public func agentInspectable() -> some View {
        let viewStore = AgentViewStore()
        return modifier(AgentInspectableModifier(viewStore: viewStore))
    }
}
