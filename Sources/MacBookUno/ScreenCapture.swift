import AppKit
import CoreMedia
import ScreenCaptureKit

/// Grabs a single frame of the internal display.
///
/// The fold effect needs the desktop's actual pixels: the content has to be
/// reshaped and blurred, and an overlay cannot touch what is behind it. This is
/// the one part of the app that requires a permission (Screen Recording).
///
/// A single frame is enough. The lid is closing, so nothing on screen is going
/// to change in a way the user can act on, and a still image costs nothing to
/// keep animating.
enum ScreenCapture {

    enum Failure: Error, CustomStringConvertible {
        case noInternalDisplay
        case denied
        case unavailable(String)

        var description: String {
            switch self {
            case .noInternalDisplay:
                return "No built-in display found to capture."
            case .denied:
                return """
                Screen Recording permission is required to capture the desktop.
                macOS grants it per binary, so a debug build and the app bundle
                each need their own. Grant it under System Settings > Privacy &
                Security > Screen Recording, then restart the app.
                """
            case .unavailable(let reason):
                return "Could not reach the display: \(reason)"
            }
        }
    }

    /// The built-in display's `CGDirectDisplayID`, or nil on a desktop Mac.
    static var internalDisplayID: CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(id) != 0 { return id }
        }
        return nil
    }

    /// Captures the built-in display, leaving our own overlay out of the frame.
    ///
    /// Excluding our own overlay is not optional: it sits above everything, so
    /// capturing it would feed the effect its own output.
    /// - Parameter excludedWindowNumber: `NSWindow.windowNumber` of our overlay.
    ///   Passed as a number rather than the window itself because the window is
    ///   main-actor isolated and this runs off the main actor.
    static func captureInternalDisplay(excludingWindowNumber excluded: Int?) async throws -> CGImage {
        guard let displayID = internalDisplayID else { throw Failure.noInternalDisplay }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            // Do not assume this is a permission problem. It usually is, but
            // reporting every failure as "denied" sends people to a settings
            // pane that is already correct.
            throw Failure.unavailable(error.localizedDescription)
        }

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.noInternalDisplay
        }

        let ourWindows: [SCWindow]
        if let excluded, excluded > 0 {
            let id = CGWindowID(excluded)
            ourWindows = content.windows.filter { $0.windowID == id }
        } else {
            ourWindows = []
        }

        let filter = SCContentFilter(display: display, excludingWindows: ourWindows)
        let configuration = SCStreamConfiguration()
        // Capture at the backing resolution so the plane stays sharp until the
        // blur is what softens it.
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best

        return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: configuration)
    }
}

/// A live feed of the built-in display.
///
/// A single frozen frame is not enough: the effect starts while the lid is still
/// at a usable angle, and a frozen screen there means you cannot see what you are
/// doing even though clicks still pass through. Frames keep arriving so the
/// desktop stays alive underneath the fold.
///
/// Frames are handed over as `IOSurface` and assigned straight to a layer, so no
/// pixels are copied and nothing is written to disk.
final class DisplayStream: NSObject, SCStreamOutput {

    private let queue = DispatchQueue(label: "MacBookUno.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var onFrame: ((IOSurfaceRef) -> Void)?

    /// True once frames are flowing, so a caller can tell "not started yet" from
    /// "started and failed".
    private(set) var isRunning = false

    /// Set for as long as the asynchronous set-up is in flight.
    ///
    /// `stream` cannot carry that on its own: it is only assigned once set-up
    /// finishes, and the frame loop calls `start` on every frame until then. So
    /// the nil check let a fresh SCStream be created on each of those frames -
    /// measured, five live captures for one fold, four of them orphaned: never
    /// stopped, and still delivering frames into the same handler.
    private var starting = false
    /// `stop` arriving while the set-up is still in flight.
    private var stopRequested = false

    /// Called on the main queue when the feed cannot start, with a message fit
    /// to show a user. Screen Recording is granted per binary, so this fires
    /// routinely during development when switching between builds.
    var onUnavailable: ((String) -> Void)?

    /// Starts the feed. `onFrame` is called on the main queue.
    func start(excludingWindowNumber excluded: Int?,
               onFrame: @escaping (IOSurfaceRef) -> Void) {
        guard stream == nil, !starting else { return }
        starting = true
        stopRequested = false
        self.onFrame = onFrame

        Task { [weak self] in
            guard let self else { return }
            guard let displayID = ScreenCapture.internalDisplayID else {
                self.report(ScreenCapture.Failure.noInternalDisplay.description)
                self.finishStarting(nil)
                return
            }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true) else {
                self.report(ScreenCapture.Failure.denied.description)
                self.finishStarting(nil)
                return
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                self.report(ScreenCapture.Failure.noInternalDisplay.description)
                self.finishStarting(nil)
                return
            }

            // Excluding our own overlay is not optional: it sits above
            // everything, so capturing it would feed the effect its own output.
            let ours: [SCWindow]
            if let excluded, excluded > 0 {
                ours = content.windows.filter { $0.windowID == CGWindowID(excluded) }
            } else {
                ours = []
            }

            let filter = SCContentFilter(display: display, excludingWindows: ours)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.queueDepth = 3
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            do {
                try stream.addStreamOutput(self, type: .screen,
                                           sampleHandlerQueue: self.queue)
                try await stream.startCapture()
            } catch {
                self.report("Could not start the screen feed: \(error.localizedDescription)")
                self.finishStarting(nil)
                return
            }
            self.finishStarting(stream)
        }
    }

    /// Adopts the stream that finished starting, or drops it if the feed was
    /// stopped while the set-up was still in flight.
    private func finishStarting(_ stream: SCStream?) {
        DispatchQueue.main.async {
            self.starting = false
            guard let stream else { return }
            guard !self.stopRequested else {
                Task { try? await stream.stopCapture() }
                return
            }
            self.stream = stream
            self.isRunning = true
        }
    }

    private func report(_ message: String) {
        guard let onUnavailable else { return }
        DispatchQueue.main.async { onUnavailable(message) }
    }

    func stop() {
        // A stop can land before the set-up finishes; remember it so the stream
        // that arrives afterwards is dropped rather than left running.
        if starting { stopRequested = true }
        guard let stream else { return }
        self.stream = nil
        isRunning = false
        onFrame = nil
        Task { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        // Layers are not thread safe and this arrives on a capture queue.
        DispatchQueue.main.async { [weak self] in self?.onFrame?(surface) }
    }
}
