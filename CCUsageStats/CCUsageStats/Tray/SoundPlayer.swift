import AppKit

/// Plays the two notification sounds used by the app. Built-in macOS
/// system sounds; no bundled audio resources.
enum SoundPlayer {
    static func playReachedLimit() {
        NSSound(named: NSSound.Name("Bottle"))?.play()
    }

    static func playLimitReset() {
        NSSound(named: NSSound.Name("Hero"))?.play()
    }
}
