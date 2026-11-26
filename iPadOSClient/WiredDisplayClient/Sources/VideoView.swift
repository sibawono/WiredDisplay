import AVFoundation
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WDGeometry
import WDSession

/// Fullscreen video surface plus input. The picture is aspect-fit; touches in
/// the letterbox are ignored (CoordinateMapper).
/// - Touch, like Sidecar (D-026): tap = click, one-finger drag = scroll with
///   momentum, hold then drag = drag/select, two-finger tap = right click,
///   two-finger drag = scroll, pinch = zoom (Command +/-), three-finger pinch
///   in/out = copy (twice: cut)/paste, three-finger swipe = undo/redo.
/// - Trackpad / mouse (Magic Keyboard): the iPad pointer is hidden and the Mac
///   cursor follows it; a click is a plain button down/up (drag, double click),
///   a two-finger click is a right click, two-finger scroll carries gesture and
///   momentum phases like a Mac trackpad.
/// - Hardware keyboard: every key press/release as a HID usage (R-INP-02).
@MainActor
final class VideoView: UIView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // layerClass guarantees the type.
        layer as! AVSampleBufferDisplayLayer // swiftlint:disable:this force_cast
    }

    static let smoothGradientsKey = "smoothGradients"
    /// Opacity just below 1 keeps iOS from promoting the full-screen video
    /// layer to a hardware overlay plane; the GPU compositor then renders it
    /// (with dithering). On the overlay plane the 10-bit picture reached the
    /// panel without dithering and smooth gradients showed rings (BUG-035).
    /// Cost: 0.1 % darker (≈0.25 of an 8-bit level) and GPU composition.
    var smoothGradients = UserDefaults.standard.object(forKey: VideoView.smoothGradientsKey) as? Bool ?? true {
        didSet { applySmoothGradients() }
    }

    private func applySmoothGradients() {
        displayLayer.opacity = smoothGradients ? 0.999 : 1
    }

    /// Host display size in points (from StreamConfig); nil until streaming.
    var streamSize: CGSize? {
        didSet { if streamSize == nil { resetTouches() } }
    }
    var onInput: ((InputEvent) -> Void)?

    /// The stream's frame rate (StreamConfig.refreshHz). Above 60 a display
    /// link asks iOS to run a ProMotion panel at up to 120 Hz while streaming
    /// (D-036): video enqueued with "display immediately" carries no frame
    /// rate, so without it the adaptive panel may stay at 60 Hz.
    var streamRefreshHz = 0 {
        didSet { if streamRefreshHz != oldValue { updateRefreshPacer() } }
    }
    private var refreshPacer: CADisplayLink?

    // MARK: Metal renderer (D-040, experimental)

    let metalRenderer = MetalVideoRenderer()
    static let metalRendererKey = "metalRenderer"

    /// Shows the Metal layer over the system display layer when on.
    var usesMetal = false {
        didSet {
            metalRenderer?.layer.isHidden = !usesMetal
            setNeedsLayout()
        }
    }

    // MARK: local cursor (D-038)

    /// The Mac cursor, drawn here from the host's position stream: it moves
    /// ~1 ms after the Mac pointer instead of with the video (~16 ms later).
    private let cursorLayer = CALayer()
    private var cursorShape: (width: CGFloat, height: CGFloat, hotX: CGFloat, hotY: CGFloat)?
    private var cursorPoint: CGPoint?
    /// While the iPad's own trackpad moves the pointer, draw it where the
    /// finger put it and ignore the (slightly older) echo from the Mac.
    private var localPointerUntil: TimeInterval = 0

    func setCursor(x: Float, y: Float, visible: Bool) {
        guard ProcessInfo.processInfo.systemUptime >= localPointerUntil else { return }
        cursorPoint = visible ? CGPoint(x: CGFloat(x), y: CGFloat(y)) : nil
        layoutCursor()
    }

    func setCursorImage(png: [UInt8], width: Float, height: Float, hotX: Float, hotY: Float) {
        guard let image = UIImage(data: Data(png))?.cgImage else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image
        CATransaction.commit()
        cursorShape = (CGFloat(width), CGFloat(height), CGFloat(hotX), CGFloat(hotY))
        layoutCursor()
    }

    private func layoutCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard streamSize != nil, let point = cursorPoint, let shape = cursorShape, let mapper else {
            cursorLayer.isHidden = true
            return
        }
        let picture = mapper.contentRect
        let width = shape.width * picture.width, height = shape.height * picture.height
        cursorLayer.frame = CGRect(x: picture.minX + point.x * picture.width - shape.hotX * width,
                                   y: picture.minY + point.y * picture.height - shape.hotY * height,
                                   width: width, height: height)
        cursorLayer.isHidden = false
    }

    /// Portrait vs landscape of the view, reported when it flips (D-039).
    var onShapeChange: ((Bool) -> Void)?
    private var lastPortrait: Bool?

    override func layoutSubviews() {
        super.layoutSubviews()
        metalRenderer?.layout(bounds: bounds, scale: window?.screen.nativeScale ?? 2)
        layoutCursor()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let portrait = bounds.height > bounds.width
        if portrait != lastPortrait {
            lastPortrait = portrait
            onShapeChange?(portrait)
        }
    }

    private func updateRefreshPacer() {
        refreshPacer?.invalidate()
        refreshPacer = nil
        guard streamRefreshHz > 60, window != nil else { return }
        let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
        let link = CADisplayLink(target: self, selector: #selector(refreshPacerTick(_:)))
        let preferred = min(Float(streamRefreshHz), maximum)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, preferred), maximum: preferred, preferred: preferred)
        link.add(to: .main, forMode: .common)
        refreshPacer = link
        ClientLog.write("refresh: stream \(streamRefreshHz) Hz, screen up to \(Int(maximum)) Hz, requested \(Int(preferred)) Hz")
    }

    @objc private func refreshPacerTick(_ link: CADisplayLink) {}

    private var interpreter = TouchInterpreter()
    /// The one direct touch the interpreter follows; other fingers belong to
    /// the multi-finger recognizers.
    private var primaryTouch: UITouch?
    private var transformTracker = TransformTracker()
    private var lastEdit: (gesture: EditGesture, time: TimeInterval)?
    private var longPress: DispatchWorkItem?
    /// Trackpad/mouse button presses in progress, with the button they hold.
    private var pointerPresses: [UITouch: PointerButton] = [:]
    private var lastPointerPoint = CGPoint(x: 0.5, y: 0.5)
    private var heldKeys = Set<UInt16>()
    private var momentum: CADisplayLink?
    private var momentumVelocity = CGPoint.zero
    private var momentumStarted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        if let metal = metalRenderer?.layer {
            metal.isHidden = true
            metal.zPosition = 5
            layer.addSublayer(metal)
        }
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        cursorLayer.magnificationFilter = .linear
        layer.addSublayer(cursorLayer)
        displayLayer.backgroundColor = UIColor.black.cgColor
        applySmoothGradients()
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        // Two-finger scroll via the system recognizer: on hardware the raw
        // touch path never saw the second finger (E-07). It also turns
        // trackpad two-finger scrolling into the same events. When it begins
        // it cancels the raw touches, which releases any drag in progress.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        addGestureRecognizer(pan)
        // Two-finger tap = right click (touch screen; a trackpad's two-finger
        // click arrives as a secondary-button press instead).
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(twoFingerTap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        // Pinch and rotate become real macOS magnify / rotate gestures (D-029),
        // from the touch screen and from a Magic Keyboard trackpad alike.
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        rotation.delegate = self
        addGestureRecognizer(rotation)
        let three = ThreeFingerRecognizer(target: self, action: #selector(threeFingers(_:)))
        addGestureRecognizer(three)
        addInteraction(UIPointerInteraction(delegate: self))
    }

    /// Scroll, pinch and rotate run together, as on a Mac trackpad.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            func isTransform(_ recognizer: UIGestureRecognizer) -> Bool {
                recognizer is UIPinchGestureRecognizer || recognizer is UIRotationGestureRecognizer
            }
            return (isTransform(gestureRecognizer) && (isTransform(other) || other is UIPanGestureRecognizer))
                || (gestureRecognizer is UIPanGestureRecognizer && isTransform(other))
        }
    }

    // MARK: multi-finger gestures

    @objc private func twoFingerTapped(_ recognizer: UITapGestureRecognizer) {
        guard streamSize != nil, recognizer.state == .ended, let point = normalized(recognizer.location(in: self)) else { return }
        let x = Float(point.x), y = Float(point.y)
        emit([.pointer(phase: .move, button: .none, x: x, y: y),
              .pointer(phase: .down, button: .right, x: x, y: y),
              .pointer(phase: .up, button: .right, x: x, y: y)])
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard streamSize != nil else { return }
        switch recognizer.state {
        case .began:
            moveCursor(to: recognizer)
            emit([transformTracker.beganPinch()])
            if let event = transformTracker.pinch(scale: recognizer.scale) { emit([event]) }
        case .changed:
            if let event = transformTracker.pinch(scale: recognizer.scale) { emit([event]) }
        case .ended: emit([TransformTracker.endPinch(cancelled: false)])
        case .cancelled, .failed: emit([TransformTracker.endPinch(cancelled: true)])
        default: break
        }
    }

    @objc private func rotated(_ recognizer: UIRotationGestureRecognizer) {
        guard streamSize != nil else { return }
        switch recognizer.state {
        case .began:
            moveCursor(to: recognizer)
            emit([transformTracker.beganRotation()])
            if let event = transformTracker.rotation(radians: recognizer.rotation) { emit([event]) }
        case .changed:
            if let event = transformTracker.rotation(radians: recognizer.rotation) { emit([event]) }
        case .ended: emit([TransformTracker.endRotation(cancelled: false)])
        case .cancelled, .failed: emit([TransformTracker.endRotation(cancelled: true)])
        default: break
        }
    }

    /// Mac gestures go to the window under the cursor: put it where the
    /// fingers (touch screen) or the pointer (trackpad) are.
    private func moveCursor(to recognizer: UIGestureRecognizer) {
        guard let point = normalized(recognizer.location(in: self)) else { return }
        emit([.pointer(phase: .move, button: .none, x: Float(point.x), y: Float(point.y))])
    }

    @objc private func threeFingers(_ recognizer: ThreeFingerRecognizer) {
        guard streamSize != nil, recognizer.state == .ended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let gesture = EditGesture.classify(startSpread: recognizer.startSpread, endSpread: recognizer.endSpread,
                                                 travel: recognizer.travel, previous: lastEdit?.gesture,
                                                 sincePrevious: now - (lastEdit?.time ?? 0)) else { return }
        NSLog("WiredDisplay: three-finger \(gesture)")
        lastEdit = (gesture, now)
        emit(gesture.keys)
    }

    // MARK: pointer and keyboard focus

    /// Only the Mac cursor is visible while streaming.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        streamSize == nil ? nil : .hidden()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRefreshPacer()
        if window != nil { becomeFirstResponder() }
    }

    // MARK: hardware keyboard

    /// Control stands in for Command for the shortcuts iPadOS keeps
    /// (Command-Tab, Command-Space, Command-Shift-3/4/5; D-030).
    private var shortcuts = ShortcutRemapper()

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard streamSize != nil, let key = press.key else { unhandled.insert(press); continue }
            let usage = UInt16(clamping: key.keyCode.rawValue)
            guard KeyMap.usageRange.contains(usage) else { unhandled.insert(press); continue }
            heldKeys.insert(usage)
            emit(shortcuts.key(usage: usage, down: true))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releasePresses(presses, with: event, cancelled: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releasePresses(presses, with: event, cancelled: true)
    }

    private func releasePresses(_ presses: Set<UIPress>, with event: UIPressesEvent?, cancelled: Bool) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, heldKeys.remove(UInt16(clamping: key.keyCode.rawValue)) != nil else {
                unhandled.insert(press)
                continue
            }
            emit(shortcuts.key(usage: UInt16(clamping: key.keyCode.rawValue), down: false))
        }
        guard !unhandled.isEmpty else { return }
        if cancelled { super.pressesCancelled(unhandled, with: event) } else { super.pressesEnded(unhandled, with: event) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: geometry

    private var mapper: CoordinateMapper? {
        guard let streamSize else { return nil }
        return CoordinateMapper(viewSize: bounds.size, displayBounds: CGRect(origin: .zero, size: streamSize))
    }

    private func normalized(_ point: CGPoint) -> CGPoint? {
        guard let mapper, let mapped = mapper.displayPoint(forViewPoint: point) else { return nil }
        let size = mapper.displayBounds.size
        return CGPoint(x: min(max(mapped.x / size.width, 0), 1), y: min(max(mapped.y / size.height, 0), 1))
    }

    /// Host points per view point, for scrolling.
    private var pointScale: CGFloat {
        guard let mapper, mapper.contentRect.width > 0 else { return 1 }
        return mapper.displayBounds.width / mapper.contentRect.width
    }

    // MARK: touches

    @objc private func twoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard streamSize != nil else { return }
        switch recognizer.state {
        case .began:
            stopMomentum()
            emit(interpreter.cancelled()) // release a drag that started with one finger
            if let point = normalized(recognizer.location(in: self)) {
                emit([.pointer(phase: .move, button: .none, x: Float(point.x), y: Float(point.y))])
            }
            recognizer.setTranslation(.zero, in: self)
            emit([.gestureScroll(dx: 0, dy: 0, phase: .began, momentum: .none)])
        case .changed:
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            let dx = Float(delta.x * pointScale), dy = Float(delta.y * pointScale)
            guard dx != 0 || dy != 0 else { return }
            emit([.gestureScroll(dx: clampScroll(dx), dy: clampScroll(dy), phase: .changed, momentum: .none)])
        case .ended:
            emit([.gestureScroll(dx: 0, dy: 0, phase: .ended, momentum: .none)])
            let velocity = recognizer.velocity(in: self)
            startMomentum(CGPoint(x: velocity.x * pointScale, y: velocity.y * pointScale))
        case .cancelled, .failed:
            emit([.gestureScroll(dx: 0, dy: 0, phase: .cancelled, momentum: .none)])
        default:
            break
        }
    }

    private func clampScroll(_ value: Float) -> Float {
        min(max(value, -SessionCodec.maxScrollDelta), SessionCodec.maxScrollDelta)
    }

    // MARK: scroll momentum (the Mac expects the device to generate it)

    /// Same deceleration as UIScrollView's normal rate (0.998 per ms).
    private static let deceleration = 0.998
    private static let minimumMomentumSpeed: CGFloat = 30 // points per second

    private func startMomentum(_ velocity: CGPoint) {
        stopMomentum()
        guard hypot(velocity.x, velocity.y) > Self.minimumMomentumSpeed * 3 else { return }
        momentumVelocity = velocity
        momentumStarted = false
        let link = CADisplayLink(target: self, selector: #selector(momentumTick(_:)))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        let dt = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        let decay = CGFloat(pow(Self.deceleration, dt * 1000))
        momentumVelocity = CGPoint(x: momentumVelocity.x * decay, y: momentumVelocity.y * decay)
        guard hypot(momentumVelocity.x, momentumVelocity.y) > Self.minimumMomentumSpeed else { return stopMomentum() }
        let dx = clampScroll(Float(momentumVelocity.x * dt)), dy = clampScroll(Float(momentumVelocity.y * dt))
        emit([.gestureScroll(dx: dx, dy: dy, phase: .none, momentum: momentumStarted ? .continue : .begin)])
        momentumStarted = true
    }

    private func stopMomentum() {
        guard let link = momentum else { return }
        link.invalidate()
        momentum = nil
        if momentumStarted { emit([.gestureScroll(dx: 0, dy: 0, phase: .none, momentum: .end)]) }
        momentumStarted = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard streamSize != nil else { return }
        stopMomentum()
        for touch in touches {
            // Trackpad/mouse click: a real button press, held until release
            // (drag, double click). Secondary (two-finger click) = right button.
            if touch.type == .indirectPointer {
                let button: PointerButton = event?.buttonMask.contains(.secondary) == true ? .right : .left
                guard let point = normalized(touch.location(in: self)) else { continue }
                pointerPresses[touch] = button
                lastPointerPoint = point
                let x = Float(point.x), y = Float(point.y)
                emit([.pointer(phase: .move, button: .none, x: x, y: y),
                      .pointer(phase: .down, button: button, x: x, y: y)])
                continue
            }
            // Only the first finger drives the interpreter.
            guard primaryTouch == nil else { continue }
            primaryTouch = touch
            let point = touch.location(in: self)
            emit(interpreter.began(viewPoint: point, normalized: normalized(point), time: touch.timestamp))
        }
        scheduleHoldIfPending()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard streamSize != nil else { return }
        for touch in touches where pointerPresses[touch] != nil {
            if let point = normalized(touch.location(in: self)) {
                lastPointerPoint = point
                emit([.pointer(phase: .move, button: .none, x: Float(point.x), y: Float(point.y))])
            }
        }
        guard let primaryTouch, touches.contains(primaryTouch) else { return }
        let point = primaryTouch.location(in: self)
        emit(interpreter.moved(viewPoint: point, normalized: normalized(point), pointScale: pointScale,
                               time: primaryTouch.timestamp))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endPointerPresses(touches)
        guard let primary = primaryTouch, touches.contains(primary) else { return }
        primaryTouch = nil
        cancelLongPress()
        emit(interpreter.ended(time: primary.timestamp))
        if let fling = interpreter.takeFling() { startMomentum(fling) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A recognizer (two or more fingers) took over, or the system did.
        endPointerPresses(touches)
        guard let primary = primaryTouch, touches.contains(primary) else { return }
        primaryTouch = nil
        cancelLongPress()
        emit(interpreter.cancelled())
    }

    private func endPointerPresses(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let button = pointerPresses.removeValue(forKey: touch) else { continue }
            let point = normalized(touch.location(in: self)) ?? lastPointerPoint
            emit([.pointer(phase: .up, button: button, x: Float(point.x), y: Float(point.y))])
        }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        // Trackpad pointer / Pencil hover: move the Mac cursor, no button.
        guard streamSize != nil, interpreter.state == .idle, pointerPresses.isEmpty,
              recognizer.state == .began || recognizer.state == .changed,
              let point = normalized(recognizer.location(in: self)) else { return }
        // Local echo happens in emit().
        emit([.pointer(phase: .move, button: .none, x: Float(point.x), y: Float(point.y))])
    }

    private func scheduleHoldIfPending() {
        guard case .pending = interpreter.state, longPress == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.longPress = nil
                self.emit(self.interpreter.holdElapsed(time: ProcessInfo.processInfo.systemUptime))
            }
        }
        longPress = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interpreter.holdDelay, execute: work)
    }

    private func cancelLongPress() {
        longPress?.cancel()
        longPress = nil
    }

    private func resetTouches() {
        stopMomentum()
        endPointerPresses(Set(pointerPresses.keys))
        if !heldKeys.isEmpty {
            emit(heldKeys.flatMap { shortcuts.key(usage: $0, down: false) })
            heldKeys.removeAll()
            shortcuts.reset()
        }
        cancelLongPress()
        primaryTouch = nil
        emit(interpreter.cancelled())
    }

    private func emit(_ events: [InputEvent]) {
        for event in events {
            // Local echo for every pointer position the iPad sends (drags,
            // trackpad clicks, touches), not only for hover (audit C-6): the
            // cursor follows at once instead of one round trip later.
            if case .pointer(_, _, let x, let y) = event {
                localPointerUntil = ProcessInfo.processInfo.systemUptime + 0.15
                cursorPoint = CGPoint(x: CGFloat(x), y: CGFloat(y))
                layoutCursor()
            }
            onInput?(event)
        }
    }
}

/// Recognizes a three-finger gesture from touch-down to lift and reports how
/// the fingers' spread and centroid changed; `EditGesture` classifies it.
/// Begins as soon as three fingers are down (a pinch barely moves the centroid,
/// so a pan recognizer would never begin).
final class ThreeFingerRecognizer: UIGestureRecognizer {
    private(set) var startSpread: CGFloat = 0
    private(set) var endSpread: CGFloat = 0
    private(set) var travel = CGVector.zero
    private var startCentroid = CGPoint.zero
    private var touches = Set<UITouch>()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    }

    override func reset() {
        super.reset()
        touches.removeAll()
        startSpread = 0
        endSpread = 0
        travel = .zero
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches.formUnion(touches)
        if self.touches.count > 3 { state = state == .possible ? .failed : .cancelled; return }
        if self.touches.count == 3, state == .possible {
            startCentroid = centroid
            startSpread = spread
            endSpread = startSpread
            state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed, self.touches.count == 3 else { return }
        endSpread = spread
        let now = centroid
        travel = CGVector(dx: now.x - startCentroid.x, dy: now.y - startCentroid.y)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            self.touches.subtract(touches)
            if self.touches.isEmpty { state = .failed }
            return
        }
        // First lift ends the gesture with the last full three-finger shape.
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    private var centroid: CGPoint {
        let points = touches.map { $0.location(in: view) }
        guard !points.isEmpty else { return .zero }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                       y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    private var spread: CGFloat {
        let center = centroid
        let points = touches.map { $0.location(in: view) }
        guard !points.isEmpty else { return 0 }
        return points.map { hypot($0.x - center.x, $0.y - center.y) }.reduce(0, +) / CGFloat(points.count)
    }
}
