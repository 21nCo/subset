import CoreGraphics
import Foundation

/// The closed set of rules that decide which windows the switcher lists. A window is listed exactly when its app
/// passes `exclusion(for:ownProcess:)` and the window passes `exclusion(for:)`:
///
/// - apps whose activation policy is not `.regular` are excluded, and so is Hop itself;
/// - subroles `AXStandardWindow` and `AXDialog` are included; every other subrole (`AXFloatingWindow`,
///   `AXSystemDialog`, any unknown one) and a missing subrole are excluded;
/// - windows narrower or shorter than 40 points, or whose size could not be read, are excluded;
/// - minimized windows and windows of hidden apps are included, and flagged on their `WindowEntry`.
///
/// Anything this set does not cover is out of scope here (SET-102), not a heuristic to add case by case.
public enum WindowFilter {
    public static let standardWindowSubrole = "AXStandardWindow"
    public static let dialogSubrole = "AXDialog"
    public static let includedSubroles: Set<String> = [standardWindowSubrole, dialogSubrole]
    /// A window must be at least this wide and this tall, in points.
    public static let minimumSide: CGFloat = 40

    public enum Exclusion: Sendable, Equatable {
        /// The app's activation policy is not `.regular`.
        case appNotRegular
        /// The app is Hop: its process, or another copy of Hop by bundle ID.
        case ownApp
        /// The subrole is not one the switcher lists; nil when the window reports none.
        case subrole(String?)
        /// The window is narrower or shorter than `minimumSide`, or its size is unknown.
        case tooSmall
    }

    /// Why an app's windows are not listed, or nil when they may be.
    public static func exclusion(for app: SourceApp, ownProcess: pid_t) -> Exclusion? {
        if app.pid == ownProcess || app.bundleIdentifier == HopIdentity.bundleIdentifier { return .ownApp }
        if app.activationPolicy != .regular { return .appNotRegular }
        return nil
    }

    /// Why a window of an eligible app is not listed, or nil when it is.
    public static func exclusion(for window: SourceWindow) -> Exclusion? {
        guard let subrole = window.subrole, includedSubroles.contains(subrole) else { return .subrole(window.subrole) }
        // Written as a negation so a NaN side, which no comparison holds for, counts as too small.
        guard let frame = window.frame, frame.width >= minimumSide, frame.height >= minimumSide else { return .tooSmall }
        return nil
    }
}
