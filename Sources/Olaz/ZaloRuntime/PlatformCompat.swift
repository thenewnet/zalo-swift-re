import Foundation
#if os(macOS)
import AppKit
/// The image type of the platform (NSImage on macOS, UIImage on iOS).
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// The few app-level services the engine needs, on macOS and on iOS. Keeps `#if os(...)` out of the engine files.
@MainActor
enum PlatformServices {
    // MARK: Pasteboard

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func copy(_ image: PlatformImage) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #else
        UIPasteboard.general.image = image
        #endif
    }

    static var pasteboardString: String {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string) ?? ""
        #else
        UIPasteboard.general.string ?? ""
        #endif
    }

    /// Uniform type identifiers on the pasteboard.
    static var pasteboardTypes: [String] {
        #if os(macOS)
        (NSPasteboard.general.types ?? []).map(\.rawValue)
        #else
        UIPasteboard.general.types
        #endif
    }

    // MARK: Opening things

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Shows a file in Finder (macOS); on iOS the file is offered through the share sheet by the UI instead.
    static func reveal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #else
        revealHandler?(url)
        #endif
    }

    /// Opens a local file with its default app (macOS) or hands it to the UI (iOS: Quick Look / share sheet).
    @discardableResult
    static func openFile(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        guard let revealHandler else { return false }
        revealHandler(url)
        return true
        #endif
    }

    #if !os(macOS)
    /// Set by the iOS app: presents a local file (Quick Look / share sheet).
    static var revealHandler: ((URL) -> Void)?
    #endif

    // MARK: App state

    static var appIsActive: Bool {
        #if os(macOS)
        NSApp?.isActive ?? true
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    static func activateApp() {
        #if os(macOS)
        NSApp?.activate()
        #endif
    }

    /// Unread badge on the Dock icon. On iOS the app badge is set by `NativeNotifier.setBadge` (sum over accounts).
    static func setDockBadge(_ count: Int) {
        #if os(macOS)
        NSApp.dockTile.badgeLabel = count <= 0 ? nil : (count > 5 ? "5+" : "\(count)")
        #endif
    }

    static var willTerminateNotification: Notification.Name {
        #if os(macOS)
        NSApplication.willTerminateNotification
        #else
        UIApplication.willTerminateNotification
        #endif
    }
}

extension PlatformImage {
    /// An image of a CGImage at its pixel size.
    static func make(cgImage: CGImage) -> PlatformImage {
        #if os(macOS)
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        UIImage(cgImage: cgImage)
        #endif
    }
}
