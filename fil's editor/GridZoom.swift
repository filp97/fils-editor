//
//  GridZoom.swift
//  fil's editor
//

import AppKit
import SwiftUI

enum GridZoom {
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 3.0
    static let step: CGFloat = 0.1

    static func clamped(_ value: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }

    static func zoomedIn(_ value: CGFloat) -> CGFloat {
        clamped(((value + step) * 10).rounded() / 10)
    }

    static func zoomedOut(_ value: CGFloat) -> CGFloat {
        clamped(((value - step) * 10).rounded() / 10)
    }

    static func percent(_ value: CGFloat) -> Int {
        Int((value * 100).rounded())
    }
}

/// Pinch, ⌘/Ctrl + scroll and ⌘/Ctrl + `+` `−` `0` zoom for the grid of the hosting window.
/// Must sit inside the grid's vertical scroll view so it can keep the visible rows anchored.
struct GridZoomMonitor: NSViewRepresentable {
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> GridZoomMonitorView {
        let view = GridZoomMonitorView()
        view.zoom = zoom
        view.onZoomChange = { zoom = $0 }
        return view
    }

    func updateNSView(_ nsView: GridZoomMonitorView, context: Context) {
        nsView.zoom = zoom
        nsView.onZoomChange = { zoom = $0 }
    }
}

final class GridZoomMonitorView: NSView {
    var zoom: CGFloat = 1
    var onZoomChange: ((CGFloat) -> Void)?

    private var monitor: Any?
    private var continuousZoom: CGFloat = 1
    private var pendingAnchor: (verticalY: CGFloat, horizontalX: CGFloat, ratio: CGFloat)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    override func removeFromSuperview() {
        removeMonitor()
        super.removeFromSuperview()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard pendingAnchor != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingAnchor()
        }
    }

    // MARK: - Events

    private var verticalScrollView: NSScrollView? { enclosingScrollView }

    private var horizontalScrollView: NSScrollView? {
        verticalScrollView?.enclosingScrollView
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        switch event.type {
        case .magnify:
            guard isInsideGrid(event) else { return false }
            if event.phase == .began {
                continuousZoom = zoom
            }
            continuousZoom = GridZoom.clamped(continuousZoom * (1 + event.magnification))
            setZoom((continuousZoom * 20).rounded() / 20)
            return true

        case .scrollWheel:
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command) || modifiers.contains(.control),
                  isInsideGrid(event) else { return false }
            if event.hasPreciseScrollingDeltas {
                if event.phase == .began || event.phase == .mayBegin {
                    continuousZoom = zoom
                }
                continuousZoom = GridZoom.clamped(continuousZoom + event.scrollingDeltaY * 0.004)
                setZoom((continuousZoom * 20).rounded() / 20)
            } else if event.scrollingDeltaY > 0 {
                setZoom(GridZoom.zoomedIn(zoom))
            } else if event.scrollingDeltaY < 0 {
                setZoom(GridZoom.zoomedOut(zoom))
            }
            return true

        case .keyDown:
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.command) || modifiers.contains(.control),
                  !modifiers.contains(.option),
                  let key = event.charactersIgnoringModifiers else { return false }
            switch key {
            case "+", "=":
                setZoom(GridZoom.zoomedIn(zoom))
            case "-", "_":
                setZoom(GridZoom.zoomedOut(zoom))
            case "0":
                setZoom(1)
            default:
                return false
            }
            return true

        default:
            return false
        }
    }

    private func isInsideGrid(_ event: NSEvent) -> Bool {
        guard let container = horizontalScrollView ?? verticalScrollView else { return false }
        let point = container.convert(event.locationInWindow, from: nil)
        return container.bounds.contains(point)
    }

    // MARK: - Zoom + scroll anchoring

    private func setZoom(_ newValue: CGFloat) {
        let target = GridZoom.clamped(newValue)
        guard abs(target - zoom) > 0.001 else { return }
        let ratio = target / zoom
        if let pending = pendingAnchor {
            pendingAnchor = (pending.verticalY, pending.horizontalX, pending.ratio * ratio)
        } else {
            pendingAnchor = (
                verticalScrollView?.contentView.bounds.origin.y ?? 0,
                horizontalScrollView?.contentView.bounds.origin.x ?? 0,
                ratio
            )
        }
        zoom = target
        onZoomChange?(target)
    }

    private func applyPendingAnchor() {
        guard let anchor = pendingAnchor else { return }
        pendingAnchor = nil

        if let scrollView = verticalScrollView,
           let documentView = scrollView.documentView, documentView.isFlipped {
            let clip = scrollView.contentView
            let maxY = max(0, documentView.frame.height - clip.bounds.height)
            let y = min(maxY, max(0, anchor.verticalY * anchor.ratio))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
        }

        if let scrollView = horizontalScrollView, let documentView = scrollView.documentView {
            let clip = scrollView.contentView
            let maxX = max(0, documentView.frame.width - clip.bounds.width)
            let x = min(maxX, max(0, anchor.horizontalX * anchor.ratio))
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}
