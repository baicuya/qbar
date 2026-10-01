import Foundation

public enum AutoHidePolicy {
    public static func shouldSchedule(enabled: Bool, expanded: Bool, moving: Bool, pointerInside: Bool) -> Bool {
        enabled && expanded && !moving && !pointerInside
    }
}
