import UIKit

@MainActor
final class Haptics {
    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let notify = UINotificationFeedbackGenerator()

    func prepare() {
        tick.prepare()
        notify.prepare()
    }

    /// One accepted shot.
    func shot() {
        tick.impactOccurred()
        tick.prepare()
    }

    /// Ring or whole capture completed.
    func success() {
        notify.notificationOccurred(.success)
        notify.prepare()
    }
}
