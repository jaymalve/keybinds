import AppKit
import SwiftUI

@MainActor
@Observable
final class PermissionsModel {
    var accessibility = Permissions.accessibilityGranted
    private var timer: Timer?

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessibility = Permissions.accessibilityGranted }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model = PermissionsModel()
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Keybinds Permissions"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window.delegate = self
        window.center()
        return window
    }()

    func show() {
        model.startPolling()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}

struct OnboardingView: View {
    let model: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keybinds needs a couple of permissions")
                .font(.title2.weight(.semibold))

            PermissionRow(
                title: "Accessibility",
                detail: "Detects double-tap Shift and lists and switches windows. Required.",
                granted: model.accessibility,
                action: ("Grant…", {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                })
            )

            PermissionRow(
                title: "Automation",
                detail: "Reads tabs from Chrome, Brave, Safari and Terminal. macOS asks the first time each app is used.",
                granted: nil,
                action: nil
            )

            Spacer()

            Text(model.accessibility
                 ? "All set. Double-tap Shift to open the palette."
                 : "After granting, this updates automatically. No restart needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520, height: 300, alignment: .topLeading)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    /// nil = requested later, on demand.
    let granted: Bool?
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted == false, let action {
                Button(action.0, action: action.1)
            }
        }
    }

    private var icon: String {
        switch granted {
        case true: "checkmark.circle.fill"
        case false: "exclamationmark.circle.fill"
        case nil: "clock"
        }
    }

    private var color: Color {
        switch granted {
        case true: .green
        case false: .orange
        case nil: .secondary
        }
    }
}
