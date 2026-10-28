// MARK: - Observations model

/// Caller-supplied observations with tri-state (yes/no/unknown).
/// These inputs are unverified assumptions supplied by the caller;
/// this decision does not establish safe identity/current Space or authorize a move,
/// and runtime H gates remain unresolved.
struct WindowObservations {
    /// Permission granted for Accessibility / AX work
    let permissionGranted: TriState
    /// App is running and unprotected (not in a protected/ restricted state)
    let appRunningUnprotected: TriState
    /// Complete snapshot of the window environment is available
    let completeSnapshot: TriState

    /// Observed windows — ordered, exactly one expected for eligibility.
    let windows: [WindowStatus]
}

extension WindowObservations {
    /// Tri-state representing yes / no / unknown
    enum TriState: String {
        case yes
        case no
        case unknown
    }
}

// MARK: - Single observed window status

/// Status of one observed window across all required conditions.
struct WindowStatus {
    let standard: WindowObservations.TriState
    let visible: WindowObservations.TriState
    let unminimized: WindowObservations.TriState
    let currentSpace: WindowObservations.TriState
    let nonFullscreen: WindowObservations.TriState
    let identifiable: WindowObservations.TriState
}

// MARK: - Decision result

/// The eligibility decision for a layout candidate.
enum LayoutCandidateEligibility {
    case eligible
    case skip(reason: SkipReason)

    /// Deterministic skip reason for when a candidate is not eligible.
    enum SkipReason: String {
        case accessibilityPermissionUnknown
        case accessibilityPermissionNotGranted
        case appNotKnownRunningOrUnprotected
        case snapshotIncomplete
        case zeroWindows
        case multipleWindows
        case windowNotStandard
        case windowStandardUnknown
        case windowNotVisible
        case windowVisibleUnknown
        case windowMinimized
        case windowMinimizedUnknown
        case windowNotInCurrentSpace
        case windowCurrentSpaceUnknown
        case windowIsFullscreen
        case windowFullscreenStatusUnknown
        case windowNotIdentifiable
        case windowIdentifiableUnknown
    }
}

// MARK: - Decision core

extension LayoutCandidateEligibility {

    /// Decide whether the observed window(s) constitute an eligible candidate for layout.
    ///
    /// Conservative matching: if ANY prerequisite is .unknown/.no, zero windows,
    /// or more than one observed window — produce a deterministic skip reason.
    /// No window IDs or capabilities are ever returned.
    ///
    /// Inputs are unverified assumptions supplied by the caller. This decision
    /// does not establish safe identity/current Space or authorize a move,
    /// and runtime H gates remain unresolved.
    static func decide(_ observations: WindowObservations) -> LayoutCandidateEligibility {
        // 1. Prerequisite checks (in order: permission, app running, snapshot)
        if observations.permissionGranted == .unknown {
            return .skip(reason: .accessibilityPermissionUnknown)
        }
        if observations.permissionGranted == .no {
            return .skip(reason: .accessibilityPermissionNotGranted)
        }
        if observations.appRunningUnprotected == .unknown {
            return .skip(reason: .appNotKnownRunningOrUnprotected)
        }
        if observations.appRunningUnprotected == .no {
            return .skip(reason: .appNotKnownRunningOrUnprotected)
        }
        if observations.completeSnapshot == .unknown {
            return .skip(reason: .snapshotIncomplete)
        }
        if observations.completeSnapshot == .no {
            return .skip(reason: .snapshotIncomplete)
        }

        // 2. Zero windows → skip
        if observations.windows.isEmpty {
            return .skip(reason: .zeroWindows)
        }

        // 3. More than one observed window → skip (ambiguity, regardless of individual eligibility)
        if observations.windows.count > 1 {
            return .skip(reason: .multipleWindows)
        }

        // 4. Exactly one window — check all conditions
        let window = observations.windows[0]

        // Window standard
        if window.standard == .unknown {
            return .skip(reason: .windowStandardUnknown)
        }
        if window.standard == .no {
            return .skip(reason: .windowNotStandard)
        }

        // Window visible
        if window.visible == .unknown {
            return .skip(reason: .windowVisibleUnknown)
        }
        if window.visible == .no {
            return .skip(reason: .windowNotVisible)
        }

        // Window unminimized
        if window.unminimized == .unknown {
            return .skip(reason: .windowMinimizedUnknown)
        }
        if window.unminimized == .no {
            return .skip(reason: .windowMinimized)
        }

        // Window current Space
        if window.currentSpace == .unknown {
            return .skip(reason: .windowCurrentSpaceUnknown)
        }
        if window.currentSpace == .no {
            return .skip(reason: .windowNotInCurrentSpace)
        }

        // Window non-fullscreen
        if window.nonFullscreen == .unknown {
            return .skip(reason: .windowFullscreenStatusUnknown)
        }
        if window.nonFullscreen == .no {
            return .skip(reason: .windowIsFullscreen)
        }

        // Window identifiable
        if window.identifiable == .unknown {
            return .skip(reason: .windowIdentifiableUnknown)
        }
        if window.identifiable == .no {
            return .skip(reason: .windowNotIdentifiable)
        }

        // All checks passed
        return .eligible
    }
}
