import SwiftUI

/// Sheet 背景点击走 SwiftUI dismiss，保持呈现状态同步。
struct SheetBackgroundDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background(SheetBackgroundClick { dismiss() })
    }
}

extension View {
    func dismissOnBackgroundClick() -> some View {
        modifier(SheetBackgroundDismiss())
    }

    func dismissConfirmationOnBackgroundClick(isPresented: Binding<Bool>) -> some View {
        background(SheetBackgroundClick(isPresented: isPresented.wrappedValue, fromSheet: false) {
            isPresented.wrappedValue = false
        })
    }
}

private struct SheetBackgroundClick: NSViewRepresentable {
    var isPresented = true
    var fromSheet = true
    let dismiss: () -> Void

    func makeNSView(context _: Context) -> MonitorView {
        let view = MonitorView()
        configure(view)
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        configure(view)
    }

    private func configure(_ view: MonitorView) {
        view.dismiss = dismiss
        view.fromSheet = fromSheet
        view.isPresented = isPresented
        view.startMonitoring()
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var dismiss: (() -> Void)?
        var isPresented = true
        var fromSheet = true
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            startMonitoring()
        }

        func startMonitoring() {
            guard isPresented, window != nil else {
                stopMonitoring()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.cancel(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func cancel(_ event: NSEvent) -> Bool {
            guard isPresented, let host = window,
                  let window = fromSheet ? host : host.attachedSheet,
                  let parent = window.sheetParent,
                  event.window === parent, parent.attachedSheet === window,
                  window.attachedSheet == nil,
                  !window.frame.contains(parent.convertPoint(toScreen: event.locationInWindow)) else { return false }
            dismiss?()
            return true
        }
    }
}
