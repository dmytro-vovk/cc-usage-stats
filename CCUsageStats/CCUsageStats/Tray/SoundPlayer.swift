import AppKit

/// Plays macOS system sounds. Built-in only; no bundled audio resources.
enum SoundPlayer {
    /// Names of built-in sounds available in `/System/Library/Sounds/`.
    static let availableSounds: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// Plays the sound of the given name. No-op if the name isn't recognized.
    static func play(named name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    static func playReachedLimit() { play(named: "Bottle") }
    static func playLimitReset()   { play(named: "Hero") }
}
