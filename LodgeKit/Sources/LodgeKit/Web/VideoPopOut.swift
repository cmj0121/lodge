/// When a tab's video moves to the mini player as the tab is left, and when it comes back as the tab is shown again.
/// The inputs come from a probe of every frame of the page.
public enum VideoPopOut {
    /// The setting that turns pop-out on or off.
    public static let settingKey = "popOutPlayingVideo"
    public static let enabledByDefault = true

    /// The tab being left pops out its video only when the setting is on and a video is playing with sound.
    public static func shouldPopOut(isPlaying: Bool, isMuted: Bool, hasVideo: Bool, isEnabled: Bool) -> Bool {
        isEnabled && hasVideo && isPlaying && !isMuted
    }

    /// The tab shown again takes its video back from the mini player.
    public static func shouldReturn(isTabShown: Bool, isInMiniPlayer: Bool) -> Bool {
        isTabShown && isInMiniPlayer
    }
}
