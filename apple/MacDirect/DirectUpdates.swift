import Sparkle

/// The direct download's updates (owner 11-25 「ota 전체적으로」): Sparkle reads SUFeedURL every 4 hours, downloads a newer
/// signed build quietly and installs it when the app quits (Info.plist SUAutomaticallyUpdate).
@MainActor enum DirectUpdates {
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}
