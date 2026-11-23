import SwiftUI

// States every data screen shows (FRONTEND-SPEC 5 and 7.6, the premium checklist): empty, no
// result, error with retry, loading without flicker, and short confirmations.

// MARK: - Empty state

/// Icon, one sentence, one action ("No runs yet. Train locally"). Wraps the system
/// ContentUnavailableView so it reads and scales like every Apple app.
struct EmptyState: View {
    @Environment(\.viaFormTheme) private var theme
    let title: String
    var message: String? = nil
    var systemImage: String = "tray"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    init(_ title: String, systemImage: String = "tray", message: String? = nil,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .font(VFFont.title)
                .foregroundStyle(theme.ink)
        } description: {
            if let message { Text(message).font(VFFont.row).foregroundStyle(theme.inkSecondary) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.vfPrimary)
            }
        }
    }
}

// MARK: - Errors

/// What went wrong and what to do: a blocking error (red) or a warning (orange), with Retry and
/// a Details disclosure for the engine's raw text.
struct InlineError: View {
    @Environment(\.viaFormTheme) private var theme
    enum Severity { case error, warning }

    let message: String
    var severity: Severity = .error
    /// The engine's own words, behind a disclosure.
    var details: String? = nil
    var retryTitle: String = String(localized: "Try Again")
    var retry: (() -> Void)? = nil
    var dismiss: (() -> Void)? = nil
    @State private var showDetails = false

    init(_ message: String, severity: Severity = .error, details: String? = nil,
         retryTitle: String = String(localized: "Try Again"), retry: (() -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        self.message = message
        self.severity = severity
        self.details = details
        self.retryTitle = retryTitle
        self.retry = retry
        self.dismiss = dismiss
    }

    private var tint: Color { severity == .error ? theme.danger : theme.warning }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: VFSpace.s) {
                Image(systemName: severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(message)
                    .font(VFFont.row)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let dismiss {
                    VFIconButton("xmark", label: String(localized: "Dismiss"), size: 10, action: dismiss)
                }
            }
            if retry != nil || details != nil {
                HStack(spacing: VFSpace.m) {
                    if let retry { Button(retryTitle, action: retry).buttonStyle(.vfSecondary) }
                    if details != nil {
                        Button(showDetails ? String(localized: "Hide Details") : String(localized: "Details")) { showDetails.toggle() }
                            .buttonStyle(.plain)
                            .font(VFFont.small)
                            .foregroundStyle(theme.accentText)
                    }
                }
            }
            if showDetails, let details {
                Text(details)
                    .font(VFFont.mono)
                    .foregroundStyle(theme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(VFSpace.m)
        .background(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous).strokeBorder(tint.opacity(0.45)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(severity == .error ? "Error" : "Warning"))
    }
}

/// A floating error over the canvas (MessageBanner's replacement): InlineError on a floating surface.
struct ErrorBanner: View {
    let message: String
    var severity: InlineError.Severity = .error
    var details: String? = nil
    var retry: (() -> Void)? = nil
    var dismiss: () -> Void

    var body: some View {
        InlineError(message, severity: severity, details: details, retry: retry, dismiss: dismiss)
            .vfSurface(.floating)
            .frame(maxWidth: 520)
    }
}

// MARK: - Loading

/// A spinner that appears only after 300 ms (FRONTEND-SPEC 7.2), so fast work never flickers.
struct DelayedProgress: View {
    var label: String? = nil
    var delay: Duration = .milliseconds(300)
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                if let label { ProgressView(label).controlSize(.small) } else { ProgressView().controlSize(.small) }
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
        .task {
            try? await Task.sleep(for: delay)
            shown = true
        }
        .accessibilityLabel(label ?? String(localized: "Loading"))
    }
}

/// A grey placeholder block for galleries and charts while they load (FRONTEND-SPEC 7.6).
struct SkeletonBlock: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce
    var cornerRadius: CGFloat = VFRadius.well
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.well)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel(Text("Loading"))
    }
}

// MARK: - Toast

/// One short confirmation ("Saved", "Removed 2 lines") with an optional action (Undo, Reveal).
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var systemImage: String = "checkmark.circle.fill"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var isError = false

    static func == (a: ToastMessage, b: ToastMessage) -> Bool { a.id == b.id }
}

/// The window's toast queue: shows one at a time for 3 s (6 s when it carries an action).
@MainActor @Observable
final class ToastCenter {
    private(set) var current: ToastMessage?
    private var timer: Task<Void, Never>?

    func show(_ t: ToastMessage) {
        current = t
        timer?.cancel()
        AccessibilityNotification.Announcement(t.text).post()
        let seconds = t.action == nil ? 3 : 6
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func show(_ text: String, systemImage: String = "checkmark.circle.fill", actionTitle: String? = nil, action: (() -> Void)? = nil) {
        show(ToastMessage(text: text, systemImage: systemImage, actionTitle: actionTitle, action: action))
    }

    func error(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        show(ToastMessage(text: text, systemImage: "exclamationmark.triangle.fill", actionTitle: actionTitle, action: action, isError: true))
    }

    func dismiss() { timer?.cancel(); current = nil }
}

extension EnvironmentValues {
    /// The window's toasts; views post confirmations here.
    @Entry var vfToasts: ToastCenter? = nil
}

struct ToastView: View {
    @Environment(\.viaFormTheme) private var theme
    let toast: ToastMessage
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: VFSpace.m) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(toast.isError ? theme.danger : theme.success)
                .accessibilityHidden(true)
            Text(toast.text).font(VFFont.row.weight(.medium)).foregroundStyle(theme.ink).lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) { action(); dismiss() }
                    .buttonStyle(.plain)
                    .font(VFFont.rowEmphasis)
                    .foregroundStyle(theme.accentText)
                    .frame(minHeight: VFSize.minTarget)
            }
        }
        .padding(.horizontal, VFSpace.l)
        .frame(minHeight: VFSize.toast)
        .vfSurface(.floating, radius: VFRadius.floating)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shows the window's toasts at the bottom of this view and puts the center in the environment.
    func toastHost(_ center: ToastCenter) -> some View {
        overlay(alignment: .bottom) {
            if let t = center.current {
                ToastView(toast: t) { center.dismiss() }
                    .padding(.bottom, VFSpace.toastLift)
                    .vfTransition(.move(edge: .bottom).combined(with: .opacity))
                    .id(t.id)
            }
        }
        .vfAnimation(.easeOut(duration: VFMotion.standard), value: center.current)
        .environment(\.vfToasts, center)
    }
}

// MARK: - Confirm

/// An outward or irreversible action to confirm (FRONTEND-SPEC 5 `ConfirmSheet`): a title, what
/// happens, and a button named by its verb ("Remove 3 Lines", "Run on Robot"), never "OK".
struct ConfirmRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// The verb on the button.
    var verb: String
    var destructive = true
    var perform: () -> Void
    /// A third choice (Don't Save), shown between the verb and Cancel.
    var alternate: (title: String, perform: () -> Void)? = nil
    var cancel: (() -> Void)? = nil
}

extension View {
    /// Presents `request` as a system alert with the verb button and Cancel; clears it after.
    func confirmSheet(_ request: Binding<ConfirmRequest?>) -> some View {
        alert(request.wrappedValue?.title ?? "", isPresented: Binding(
            get: { request.wrappedValue != nil },
            set: { if !$0 { request.wrappedValue = nil } }
        ), presenting: request.wrappedValue) { r in
            Button(r.verb, role: r.destructive ? .destructive : nil) { r.perform() }
                .keyboardShortcut(.defaultAction)
            if let alt = r.alternate {
                Button(alt.title, role: .destructive) { alt.perform() }
            }
            Button("Cancel", role: .cancel) { r.cancel?() }
        } message: { r in
            Text(r.message)
        }
    }
}
