import SwiftUI
import UIKit

/// Two fingers on the photo: pinch to zoom and drag to move, at the same time. SwiftUI's MagnifyGesture only reports
/// where a pinch began and doesn't start when two fingers move without spreading, so these use UIKit's pinch and
/// two-finger pan, which both report where the fingers are now (their middle point, in the view's own space).
/// Attach both with `.gesture`; their delegate lets them run with each other and the photo's SwiftUI gestures. Each reports its state, the middle point and (pinch only) the scale.
struct PinchRecognizer: UIGestureRecognizerRepresentable {
    var onEvent: (_ state: UIGestureRecognizer.State, _ centre: CGPoint, _ scale: CGFloat?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let g = UIPinchGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPinchGestureRecognizer, context: Context) {
        onEvent(g.state, context.converter.localLocation, g.scale)
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> SimultaneousDelegate { SimultaneousDelegate() }
}

struct TwoFingerPanRecognizer: UIGestureRecognizerRepresentable {
    var onEvent: (_ state: UIGestureRecognizer.State, _ centre: CGPoint, _ scale: CGFloat?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.minimumNumberOfTouches = 2
        g.maximumNumberOfTouches = 2
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        onEvent(g.state, context.converter.localLocation, nil)
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> SimultaneousDelegate { SimultaneousDelegate() }
}

/// Lets the pinch, the two-finger pan and the rest of the photo's gestures run together.
final class SimultaneousDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
