import Foundation

/// What macOS says when it asks the user to let the app use Location Services (triggers spec
/// §1.14, §2.3, TS-7): only Wi-Fi triggers need it, because macOS shows the Wi-Fi network's name
/// only to apps allowed to use Location Services. The app asks only when the user clicks Allow… in
/// a Wi-Fi trigger, and never reads a location.
///
/// An Info.plist string of the main app only (`Resources/Info.plist`, kept equal to this by
/// `LocationPurposeTests`): standalone groups' own apps never read networks, so their Info.plist
/// (`AgentInfoPlist`) doesn't have it, and their ad hoc signature has no Location entitlement.
/// English only, as the file access purposes are (`FileAccessPurposes`).
public enum LocationPurpose {
    public static let infoPlistKey = "NSLocationUsageDescription"

    public static let infoPlistEntries: [String: String] = [
        infoPlistKey:
            "Cybokron Dock Groups reads the name of the Wi-Fi network your Mac is on, only to run the triggers you set for Wi-Fi networks. macOS treats network names as location information. Your location is never read, kept or sent anywhere.",
    ]

    /// The entitlement the hardened runtime needs before macOS even asks (TS-7).
    public static let entitlement = "com.apple.security.personal-information.location"
}
