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

    /// A `.presentation` message for the tab in Picture in Picture. Leaving PiP (mode not `.pictureInPicture`) while
    /// the tab is not shown: still playing → `.restore`, paused → `.close`. While shown, or still in PiP → `.none`.
    public static func exit(mode: VideoPopOutScript.PresentationMode, isPaused: Bool, isTabShown: Bool) -> PiPExit {
        guard mode != .pictureInPicture, !isTabShown else { return .none }
        return isPaused ? .close : .restore
    }
}

/// What a Picture in Picture video's leaving it means for its tab (iOS, `VideoPopOut.exit`).
public enum PiPExit: Equatable, Sendable {
    /// The user asked for the video back: show its workspace and tab.
    case restore
    /// The user closed it: the tab stays where it is.
    case close
    case none
}
