/// macOS brightness-key steps (D-033): 16 steps, or 64 with Option-Shift,
/// snapped to the step grid like the system does. Pure, for tests.
public enum BrightnessStep {
    public static func next(from value: Float, up: Bool, fine: Bool) -> Float {
        let steps: Float = fine ? 64 : 16
        let position = value * steps
        // Snap first so an off-grid value (e.g. set in Control Center) moves to
        // the next grid point in the pressed direction, never back.
        let target = up ? (position + 0.001).rounded(.down) + 1 : (position - 0.001).rounded(.up) - 1
        return min(max(target / steps, 0), 1)
    }
}
