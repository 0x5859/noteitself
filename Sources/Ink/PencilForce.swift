import CoreGraphics

/// Turns the force UIKit reports for an Apple Pencil into the 0…1 pressure
/// the stroke builder works with. One value per stroke.
///
/// The Pencil measures force itself and sends it over Bluetooth, so it
/// arrives a little after the touch. Until the first measurement is in,
/// UIKit fills the gap with a placeholder: the same constant at the start of
/// every stroke, whatever the hand is doing. Taken at face value it gives
/// each stroke a blob at its start, sized for a moderate press. A tip that
/// has just landed is in fact pressing with next to nothing, so until the
/// reported force first changes this reports no pressure, and the line
/// swells in from a point as the measurements arrive.
struct PencilForce {
    /// Force, in UIKit units, that counts as full pressure.
    static let fullScale: CGFloat = 1.8
    /// How many identical samples (at 240 Hz) to sit out before believing
    /// that a force which never changes is simply what the stylus reports.
    static let patience = 8

    private var placeholder: CGFloat?
    private var repeats = 0
    private var measured = false

    /// - Parameter expectsUpdate: UIKit has promised a corrected value for
    ///   this sample (`estimatedPropertiesExpectingUpdates`).
    mutating func pressure(force: CGFloat, expectsUpdate: Bool) -> CGFloat {
        if !measured {
            if let placeholder {
                if force != placeholder {
                    measured = true
                } else {
                    repeats += 1
                    if repeats >= PencilForce.patience, !expectsUpdate { measured = true }
                }
            } else {
                placeholder = force
            }
        }
        return measured ? min(1, max(0, force) / PencilForce.fullScale) : 0
    }
}
