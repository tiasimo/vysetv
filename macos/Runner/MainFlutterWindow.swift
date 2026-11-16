import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Full screen is for watching: the menu bar and the title bar hide there, also on a Mac
    // set to keep its menu bar in full screen. This is that system setting, for VyseTV only.
    UserDefaults.standard.set(false, forKey: "AppleMenuBarVisibleInFullscreen")

    let flutterViewController = FlutterViewController()
    // Plezy's player: the video is a layer *behind* Flutter's. The window stays
    // opaque (cheaper for WindowServer); Flutter is clear so the video shows.
    self.isOpaque = true
    self.backgroundColor = NSColor.black
    flutterViewController.backgroundColor = NSColor.clear

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Plezy's mpv player (Runner/MpvPlayer): video + PiP, and two audio-only
    // cores (music, audiobooks).
    MpvPlayerPlugin.register(with: flutterViewController.registrar(forPlugin: "MpvPlayerPlugin"))
    MpvAudioPlayerPlugin.register(with: flutterViewController.registrar(forPlugin: "MpvAudioPlayerPlugin"))
    MpvAudioPlayerPlugin.registerSecondary(with: flutterViewController.registrar(forPlugin: "MpvAudio2PlayerPlugin"))

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}

// The window's delegate is the window_manager plugin's object, and it leaves one question
// unanswered: what full screen should hide. This answers it the way Plezy's own window does:
// the menu bar, the title bar and the Dock all stay out of the way until the pointer goes to
// the edge.
extension WindowManager {
  @objc public func window(
    _ window: NSWindow,
    willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
  ) -> NSApplication.PresentationOptions {
    return [.fullScreen, .autoHideMenuBar, .autoHideToolbar, .autoHideDock]
  }
}
