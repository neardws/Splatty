import UIKit

@MainActor
final class Haptics {
    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let notify = UINotificationFeedbackGenerator()
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)

    func prepare() {
        tick.prepare()
        notify.prepare()
        rigid.prepare()
    }

    /// One accepted shot.
    func shot() {
        tick.impactOccurred()
        tick.prepare()
    }

    /// "Too fast": two firm taps, distinct from the single light shot tick.
    func doubleTap() {
        rigid.impactOccurred(intensity: 1)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            self.rigid.impactOccurred(intensity: 1)
            self.rigid.prepare()
        }
    }

    /// Ring or whole capture completed.
    func success() {
        notify.notificationOccurred(.success)
        notify.prepare()
    }
}
