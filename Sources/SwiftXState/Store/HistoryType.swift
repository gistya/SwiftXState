/// Whether a history state restores only the direct child (`shallow`) or the full nested
/// configuration (`deep`).
public enum HistoryType: Sendable {
    case shallow
    case deep
}
