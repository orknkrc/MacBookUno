import Foundation
import ServiceManagement

/// Registers the app to launch at login.
///
/// `SMAppService` replaced the old login-item APIs and needs nothing but the
/// bundle itself - no helper target, no shared file list, no extra
/// entitlement - which is why it is worth using rather than telling people to
/// add the app by hand in System Settings.
///
/// Two things it will not do, and both are reported rather than hidden:
///
/// - It needs a real bundle. Under `swift run` there is no `.app`, so
///   registration fails, and saying so is more use than a checkbox that
///   silently does nothing.
/// - The user can still refuse it in System Settings, and macOS reports that
///   as `requiresApproval` rather than an error. The app is registered but will
///   not actually launch until they allow it.
enum LoginItem {

    enum State {
        case on
        case off
        /// Registered, but the user has not allowed it in System Settings yet.
        case needsApproval
    }

    /// `notFound` is reported as simply off rather than as unavailable.
    ///
    /// It is what this app gets from a stock build, wherever the bundle lives -
    /// measured from the build directory, from `~/Applications` and from a
    /// temporary directory, all three - and the cause is not something the app
    /// can establish. A self-signed bundle carries no Team ID, which is the
    /// likeliest reason macOS has no record to report on, but that is a guess.
    ///
    /// Presenting a guess as a greyed-out row is worse than letting the user
    /// press the switch and showing whatever macOS says if it refuses.
    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    /// Returns nil on success, or a message worth showing the user.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // The common case by far is running from `swift run` rather than a
            // bundle, so the message names it instead of only echoing errno.
            if Bundle.main.bundleURL.pathExtension != "app" {
                return "Open at Login needs the app bundle. Build it with "
                     + "Scripts/make-app.sh and run that instead."
            }
            return "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
