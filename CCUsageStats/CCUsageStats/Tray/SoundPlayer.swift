import AppKit

/// Plays macOS system sounds. Built-in only; no bundled audio resources.
enum SoundPlayer {
    /// Sentinel option in the per-event sound pickers — selecting it
    /// silences just that one event.
    static let none = "None"

    /// Names of built-in sounds available in `/System/Library/Sounds/`.
    static let availableSounds: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// Picker-facing list with the "None" sentinel at the top so users
    /// can mute individual events without a global toggle.
    static let pickableSounds: [String] = [Self.none] + availableSounds

    /// Plays the sound of the given name. No-op if the name is the
    /// "None" sentinel or not a recognized system sound.
    static func play(named name: String) {
        guard name != Self.none else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
