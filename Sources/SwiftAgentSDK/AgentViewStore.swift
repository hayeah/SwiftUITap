import SwiftUI
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Stores view inspection data: frames, layout info, and root platform view reference.
/// Used by the view inspection protocol (POST /view).
@MainActor
public final class AgentViewStore {
    /// Shared instance — set by .agentInspectable(), read by DebugLayout and Poller.
    public static var active: AgentViewStore?

    /// Resolved anchor frames, keyed by qualified agentID.
    public var frames: [String: CGRect] = [:]

    /// Layout negotiation info from DebugLayout passthrough.
    public var layoutInfo: [String: LayoutInfo] = [:]

    #if canImport(AppKit)
    /// Root NSView for screenshots and view hierarchy walking.
    public weak var rootView: NSView?
    #elseif canImport(UIKit)
    /// Root UIView for screenshots and view hierarchy walking.
    public weak var rootView: UIView?
    #endif

    /// Offset from rootView origin to SwiftUI content origin.
    /// SwiftUI frame coordinates need this offset added to match UIView coordinates.
    public var contentOffset: CGPoint = .zero

    public struct LayoutInfo {
        public var proposedWidth: CGFloat?
        public var proposedHeight: CGFloat?
        public var reported: CGSize

        public init(proposedWidth: CGFloat?, proposedHeight: CGFloat?, reported: CGSize) {
            self.proposedWidth = proposedWidth
            self.proposedHeight = proposedHeight
            self.reported = reported
        }
    }

    public init() {}

    // MARK: - Dispatch

    public func dispatch(_ request: [String: Any]) -> AgentResult {
        guard let type = request["type"] as? String else {
            return .error("missing 'type' field")
        }
        switch type {
        case "tree":
            return tree(id: request["id"] as? String)
        case "screenshot":
            return screenshot(request)
        case "get":
            return platformGet(request)
        case "set":
            return platformSet(request)
        case "call":
            return platformCall(request)
        case "debug":
            return debugViewHierarchy()
        default:
            return .error("unknown view type: \(type)")
        }
    }

    // MARK: - Tree

    func tree(id: String?) -> AgentResult {
        // Build flat list of nodes with absolute frames (offset to match screenshot coordinates)
        let offset = contentOffset
        var absFrames: [String: CGRect] = [:]
        var nodes: [(id: String, frame: CGRect, proposed: LayoutInfo?)] = []
        for (nodeID, frame) in frames {
            let absFrame = frame.offsetBy(dx: offset.x, dy: offset.y)
            absFrames[nodeID] = absFrame
            let layout = layoutInfo[nodeID]
            nodes.append((id: nodeID, frame: absFrame, proposed: layout))
        }

        // Sort by area descending (largest first) for containment check
        nodes.sort { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }

        // Build parent map from spatial containment
        var parentMap: [String: String] = [:]
        let sortedByAreaAsc = nodes.reversed()
        for node in sortedByAreaAsc {
            var bestParent: String?
            var bestArea: CGFloat = .infinity
            for candidate in nodes {
                if candidate.id == node.id { continue }
                let area = candidate.frame.width * candidate.frame.height
                if candidate.frame.contains(node.frame) && area < bestArea {
                    bestArea = area
                    bestParent = candidate.id
                }
            }
            if let parent = bestParent {
                parentMap[node.id] = parent
            }
        }

        // Collect children per parent
        var childrenIDs: [String: [String]] = [:]
        for node in nodes { childrenIDs[node.id] = [] }
        for (child, parent) in parentMap {
            childrenIDs[parent]?.append(child)
        }

        // Build tree recursively with relative frames
        func buildNode(_ nodeID: String) -> [String: Any] {
            let absFrame = absFrames[nodeID]!
            let layout = layoutInfo[nodeID]
            let parentID = parentMap[nodeID]
            let parentFrame = parentID.flatMap { absFrames[$0] }

            var dict: [String: Any] = [
                "id": nodeID,
                "frame": rectToDict(absFrame),
            ]

            // Relative frame: position relative to parent's origin
            if let pf = parentFrame {
                dict["relativeFrame"] = rectToDict(CGRect(
                    x: absFrame.origin.x - pf.origin.x,
                    y: absFrame.origin.y - pf.origin.y,
                    width: absFrame.width,
                    height: absFrame.height
                ))
            }

            if let layout = layout {
                dict["proposed"] = [
                    "w": layout.proposedWidth.map { $0 as Any } ?? NSNull(),
                    "h": layout.proposedHeight.map { $0 as Any } ?? NSNull(),
                ] as [String: Any]
                dict["reported"] = [
                    "w": layout.reported.width,
                    "h": layout.reported.height,
                ]
            }

            let kids = (childrenIDs[nodeID] ?? []).map { buildNode($0) }
            if !kids.isEmpty {
                dict["children"] = kids
            }
            return dict
        }

        // Find roots (nodes with no parent)
        let rootIDs = nodes.map(\.id).filter { parentMap[$0] == nil }

        // If scoped to a specific id, return that subtree
        if let id = id {
            guard absFrames[id] != nil else {
                return .error("unknown view id: \(id)")
            }
            return .value(buildNode(id))
        }

        if rootIDs.count == 1 {
            return .value(buildNode(rootIDs[0]))
        }
        return .value(rootIDs.map { buildNode($0) })
    }

    // MARK: - Screenshot

    func screenshot(_ request: [String: Any]) -> AgentResult {
        #if canImport(AppKit)
        guard let view = rootView, let window = view.window else {
            return .error("no root view available for screenshot")
        }

        // Capture the full window content
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return .error("failed to create bitmap rep")
        }
        view.cacheDisplay(in: bounds, to: rep)

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return .error("failed to encode PNG")
        }

        var result: [String: Any] = [
            "image": pngData.base64EncodedString(),
            "format": "png",
            "size": ["w": bounds.width, "h": bounds.height],
            "scale": window.backingScaleFactor,
        ]

        // Include frames so server can crop
        if request["id"] != nil {
            // Send offset-adjusted frames so server can crop correctly
            let offset = contentOffset
            var framesDict: [String: Any] = [:]
            for (id, frame) in frames {
                framesDict[id] = rectToDict(frame.offsetBy(dx: offset.x, dy: offset.y))
            }
            result["frames"] = framesDict
        }

        return .value(result)

        #elseif canImport(UIKit)
        guard let view = rootView else {
            return .error("no root view available for screenshot")
        }

        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { ctx in
            // drawHierarchy captures the actual composited screen output
            // including nav bar blur, vibrancy, and other visual effects.
            // layer.render misses these.
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }

        guard let pngData = image.pngData() else {
            return .error("failed to encode PNG")
        }

        var result: [String: Any] = [
            "image": pngData.base64EncodedString(),
            "format": "png",
            "size": ["w": view.bounds.width, "h": view.bounds.height],
            "scale": UIScreen.main.scale,
        ]

        if request["id"] != nil {
            // Send offset-adjusted frames so server can crop correctly
            let offset = contentOffset
            var framesDict: [String: Any] = [:]
            for (id, frame) in frames {
                framesDict[id] = rectToDict(frame.offsetBy(dx: offset.x, dy: offset.y))
            }
            result["frames"] = framesDict
        }

        return .value(result)
        #else
        return .error("screenshot not supported on this platform")
        #endif
    }

    // MARK: - KVC Get/Set/Call on backing platform view

    func platformGet(_ request: [String: Any]) -> AgentResult {
        guard let id = request["id"] as? String else {
            return .error("get requires 'id'")
        }
        guard let view = findPlatformView(forAgentID: id) else {
            return .error("no backing view for id: \(id)")
        }
        let viewClass = String(describing: type(of: view))

        // Multi-get
        if let paths = request["path"] as? [String] {
            var result: [String: Any] = [:]
            for kp in paths {
                result[kp] = serializeValue(view.value(forKeyPath: kp))
            }
            return .value(["data": result, "viewClass": viewClass])
        }

        // Single get
        guard let path = request["path"] as? String else {
            return .error("get requires 'path'")
        }
        let val = view.value(forKeyPath: path)
        return .value(["data": serializeValue(val), "viewClass": viewClass])
    }

    func platformSet(_ request: [String: Any]) -> AgentResult {
        guard let id = request["id"] as? String else {
            return .error("set requires 'id'")
        }
        guard let view = findPlatformView(forAgentID: id) else {
            return .error("no backing view for id: \(id)")
        }
        guard let path = request["path"] as? String else {
            return .error("set requires 'path'")
        }
        let viewClass = String(describing: type(of: view))
        view.setValue(request["value"], forKeyPath: path)
        return .value(["viewClass": viewClass])
    }

    func platformCall(_ request: [String: Any]) -> AgentResult {
        guard let id = request["id"] as? String else {
            return .error("call requires 'id'")
        }
        guard let view = findPlatformView(forAgentID: id) else {
            return .error("no backing view for id: \(id)")
        }
        guard let method = request["method"] as? String else {
            return .error("call requires 'method'")
        }
        let viewClass = String(describing: type(of: view))
        let sel = NSSelectorFromString(method)
        guard view.responds(to: sel) else {
            return .error("\(viewClass) does not respond to \(method)")
        }
        // Simple no-arg selector call
        _ = view.perform(sel)
        return .value(["viewClass": viewClass])
    }

    // MARK: - Debug

    func debugViewHierarchy() -> AgentResult {
        guard let root = rootView else {
            return .error("no root view — rootView is nil")
        }
        var entries: [[String: Any]] = []
        walkViewTree(root, depth: 0, entries: &entries)
        return .value([
            "rootType": String(describing: type(of: root)),
            "viewCount": entries.count,
            "views": entries,
        ])
    }

    #if canImport(AppKit)
    private func walkViewTree(_ view: NSView, depth: Int, entries: inout [[String: Any]]) {
        var entry: [String: Any] = [
            "depth": depth,
            "class": String(describing: type(of: view)),
            "frame": rectToDict(view.frame),
        ]
        let aid = view.accessibilityIdentifier() as String?
        if let aid, !aid.isEmpty {
            entry["accessibilityIdentifier"] = aid
        }
        entries.append(entry)
        for subview in view.subviews {
            walkViewTree(subview, depth: depth + 1, entries: &entries)
        }
    }
    #elseif canImport(UIKit)
    private func walkViewTree(_ view: UIView, depth: Int, entries: inout [[String: Any]]) {
        var entry: [String: Any] = [
            "depth": depth,
            "class": String(describing: type(of: view)),
            "frame": rectToDict(view.frame),
        ]
        if let aid = view.accessibilityIdentifier, !aid.isEmpty {
            entry["accessibilityIdentifier"] = aid
        }
        entries.append(entry)
        for subview in view.subviews {
            walkViewTree(subview, depth: depth + 1, entries: &entries)
        }
    }
    #endif

    // MARK: - Helpers

    /// Find the backing platform view for a tagged agentID.
    /// Strategy: match the agentID's resolved frame against UIView/NSView frames.
    /// The closest-sized view whose frame overlaps the agentID frame is returned.
    private func findViewClass(for id: String) -> String? {
        guard let view = findPlatformView(forAgentID: id) else { return nil }
        return String(describing: type(of: view))
    }

    #if canImport(AppKit)
    private func findPlatformView(forAgentID id: String) -> NSView? {
        guard let root = rootView, let swiftuiFrame = frames[id] else { return nil }
        // Offset SwiftUI frame to rootView coordinates
        let targetFrame = swiftuiFrame.offsetBy(dx: contentOffset.x, dy: contentOffset.y)
        return findBestMatch(in: root, targetFrame: targetFrame)
    }

    private func findBestMatch(in root: NSView, targetFrame: CGRect) -> NSView? {
        var best: NSView?
        var bestScore: CGFloat = .infinity
        findBestMatchRecursive(root, targetFrame: targetFrame, best: &best, bestScore: &bestScore)
        return best
    }

    private func findBestMatchRecursive(_ view: NSView, targetFrame: CGRect, depth: Int = 0, best: inout NSView?, bestScore: inout CGFloat) {
        guard !view.isHidden, view.frame.width > 0, view.frame.height > 0 else { return }

        let frameInRoot = view.superview?.convert(view.frame, to: rootView) ?? view.frame

        let viewType = String(describing: type(of: view))
        let score = frameMatchScore(frameInRoot, targetFrame, depth: depth)
        if score < bestScore && score < 40 && !isSwiftUIWrapper(viewType) {
            bestScore = score
            best = view
        }
        for subview in view.subviews {
            findBestMatchRecursive(subview, targetFrame: targetFrame, depth: depth + 1, best: &best, bestScore: &bestScore)
        }
    }
    #elseif canImport(UIKit)
    private func findPlatformView(forAgentID id: String) -> UIView? {
        guard let root = rootView, let swiftuiFrame = frames[id] else { return nil }
        let targetFrame = swiftuiFrame.offsetBy(dx: contentOffset.x, dy: contentOffset.y)
        return findBestMatch(in: root, targetFrame: targetFrame)
    }

    private func findBestMatch(in root: UIView, targetFrame: CGRect) -> UIView? {
        var best: UIView?
        var bestScore: CGFloat = .infinity
        findBestMatchRecursive(root, targetFrame: targetFrame, best: &best, bestScore: &bestScore)
        return best
    }

    private func findBestMatchRecursive(_ view: UIView, targetFrame: CGRect, depth: Int = 0, best: inout UIView?, bestScore: inout CGFloat) {
        guard !view.isHidden, view.frame.width > 0, view.frame.height > 0 else { return }

        let frameInRoot = view.superview?.convert(view.frame, to: rootView) ?? view.frame

        let viewType = String(describing: type(of: view))
        let score = frameMatchScore(frameInRoot, targetFrame, depth: depth)
        if score < bestScore && score < 40 && !isSwiftUIWrapper(viewType) {
            bestScore = score
            best = view
        }
        for subview in view.subviews {
            findBestMatchRecursive(subview, targetFrame: targetFrame, depth: depth + 1, best: &best, bestScore: &bestScore)
        }
    }
    #endif

    /// Score how well two frames match. Lower = better. 0 = exact match.
    private func frameMatchScore(_ a: CGRect, _ b: CGRect, depth: Int = 0) -> CGFloat {
        let posScore = abs(a.origin.x - b.origin.x) + abs(a.origin.y - b.origin.y)
        let sizeScore = (abs(a.size.width - b.size.width) + abs(a.size.height - b.size.height)) * 0.5
        return posScore + sizeScore
    }

    /// Returns true if this view is a SwiftUI internal wrapper (not a "real" UIKit view).
    private func isSwiftUIWrapper(_ viewType: String) -> Bool {
        viewType.contains("PlatformViewHost") ||
        viewType.contains("HostingView") ||
        viewType.contains("ViewControllerWrapper") ||
        viewType.contains("TransitionView")
    }

    private func rectToDict(_ rect: CGRect) -> [String: CGFloat] {
        ["x": rect.origin.x, "y": rect.origin.y, "w": rect.size.width, "h": rect.size.height]
    }

    private func serializeValue(_ value: Any?) -> Any {
        guard let value = value else { return NSNull() }

        switch value {
        case let n as NSNumber: return n
        case let s as String: return s
        case let b as Bool: return b
        #if canImport(AppKit)
        case let p as NSPoint: return ["x": p.x, "y": p.y]
        case let s as NSSize: return ["w": s.width, "h": s.height]
        case let r as NSRect: return rectToDict(r)
        #endif
        case let p as CGPoint: return ["x": p.x, "y": p.y]
        case let s as CGSize: return ["w": s.width, "h": s.height]
        case let r as CGRect: return rectToDict(r)
        default: return String(describing: value)
        }
    }
}
