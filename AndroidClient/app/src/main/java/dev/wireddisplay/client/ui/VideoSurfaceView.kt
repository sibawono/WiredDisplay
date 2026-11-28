package dev.wireddisplay.client.ui

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Choreographer
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import android.widget.ImageView
import dev.wireddisplay.client.input.AndroidKeyMap
import dev.wireddisplay.client.input.CoordinateMapper
import dev.wireddisplay.client.input.EditGesture
import dev.wireddisplay.client.input.PointF
import dev.wireddisplay.client.input.ShortcutRemapper
import dev.wireddisplay.client.input.TouchInterpreter
import dev.wireddisplay.client.input.TransformTracker
import dev.wireddisplay.client.session.CursorImage
import dev.wireddisplay.client.session.InputEvent
import dev.wireddisplay.client.session.MomentumPhase
import dev.wireddisplay.client.session.PointerButton
import dev.wireddisplay.client.session.PointerPhase
import dev.wireddisplay.client.session.ScrollPhase
import dev.wireddisplay.client.session.SessionConstants
import dev.wireddisplay.client.session.StreamConfig
import dev.wireddisplay.client.video.MediaCodecVideoDecoder
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.pow

enum class StylusAction(val title: String) {
    OFF("Off"),
    RIGHT_CLICK("Right Click"),
    UNDO("Undo (⌘Z)")
}

/**
 * Fullscreen hardware video SurfaceView + local cursor overlay + multi-touch, stylus, mouse,
 * and hardware keyboard input forwarding matching iPad VideoView.swift.
 */
class VideoSurfaceView(
    context: Context,
    private val decoder: MediaCodecVideoDecoder
) : FrameLayout(context) {

    var onInput: ((InputEvent) -> Unit)? = null
    var onShapeChange: ((portrait: Boolean) -> Unit)? = null
    var stylusAction: StylusAction = StylusAction.RIGHT_CLICK

    private val surfaceView = SurfaceView(context)
    private val cursorView = ImageView(context).apply {
        visibility = GONE
        scaleType = ImageView.ScaleType.FIT_XY
    }

    private var streamConfig: StreamConfig? = null
    private var mapper: CoordinateMapper? = null
    private var lastPortrait: Boolean? = null

    private var cursorNormX = 0.5f
    private var cursorNormY = 0.5f
    private var cursorVisible = false
    private var cursorShape: CursorImage? = null
    private var localPointerUntilMs = 0L

    private val mainHandler = Handler(Looper.getMainLooper())
    private val interpreter = TouchInterpreter(slopPx = 12f * resources.displayMetrics.density)
    private val transformTracker = TransformTracker()
    private val shortcuts = ShortcutRemapper()
    private val heldKeys = HashSet<Int>()

    private var primaryPointerId = MotionEvent.INVALID_POINTER_ID
    private var holdRunnable: Runnable? = null
    private var stylusPointerId = MotionEvent.INVALID_POINTER_ID
    private var lastStylusNorm = PointF(0.5f, 0.5f)
    private var lastStylusButtonMask = 0
    private var palmRejectUntilMs = 0L

    private var mouseButtonHeld: PointerButton? = null
    private var lastMouseNorm = PointF(0.5f, 0.5f)

    private var twoFingerActive = false
    private var twoFingerStartMs = 0L
    private var twoFingerMoved = false
    private var twoFingerLastCx = 0f
    private var twoFingerLastCy = 0f
    private var twoFingerStartDist = 0f
    private var twoFingerStartAngle = 0f
    private var twoFingerPinchStarted = false
    private var twoFingerRotateStarted = false

    private var threeFingerActive = false
    private var threeStartCx = 0f
    private var threeStartCy = 0f
    private var threeStartSpread = 0f
    private var threeEndSpread = 0f
    private var threeTravelDx = 0f
    private var threeTravelDy = 0f
    private var lastEditGesture: EditGesture? = null
    private var lastEditTimeSec = 0.0

    private var momentumActive = false
    private var momentumStarted = false
    private var momentumVx = 0f
    private var momentumVy = 0f
    private var momentumLastNs = 0L
    private val momentumCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!momentumActive) return
            val dt = ((frameTimeNanos - momentumLastNs) / 1e9).coerceAtLeast(1.0 / 120.0).toFloat()
            momentumLastNs = frameTimeNanos
            val decay = 0.998.pow(dt * 1000.0).toFloat()
            momentumVx *= decay
            momentumVy *= decay
            if (hypot(momentumVx, momentumVy) <= 30f) {
                stopMomentum()
                return
            }
            val limit = SessionConstants.MAX_SCROLL_DELTA
            val dx = (momentumVx * dt).coerceIn(-limit, limit)
            val dy = (momentumVy * dt).coerceIn(-limit, limit)
            emit(
                listOf(
                    InputEvent.GestureScroll(
                        dx, dy, ScrollPhase.NONE,
                        if (momentumStarted) MomentumPhase.CONTINUE else MomentumPhase.BEGIN
                    )
                )
            )
            momentumStarted = true
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    init {
        setBackgroundColor(Color.BLACK)
        isFocusable = true
        isFocusableInTouchMode = true
        addView(surfaceView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER))
        addView(cursorView, LayoutParams(1, 1))

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                decoder.setSurface(holder.surface)
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                decoder.setSurface(holder.surface)
            }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                decoder.setSurface(null)
            }
        })
    }

    fun updateStreamConfig(config: StreamConfig?) {
        if (streamConfig == config) return
        streamConfig = config
        if (config == null) {
            resetTouches()
            cursorVisible = false
            cursorView.visibility = GONE
        }
        updateGeometry()
    }

    fun setCursor(x: Float, y: Float, visible: Boolean) {
        if (SystemClock.uptimeMillis() < localPointerUntilMs) return
        cursorNormX = x
        cursorNormY = y
        cursorVisible = visible
        layoutCursor()
    }

    fun setCursorImage(image: CursorImage) {
        val bmp = BitmapFactory.decodeByteArray(image.png, 0, image.png.size) ?: return
        cursorShape = image
        cursorView.setImageBitmap(bmp)
        layoutCursor()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        updateGeometry()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && w > 0 && h > 0) {
            val edge = (24 * resources.displayMetrics.density).toInt()
            val maxStrip = (200 * resources.displayMetrics.density).toInt().coerceAtMost(h)
            val top = (h - maxStrip) / 2
            systemGestureExclusionRects = listOf(
                Rect(0, top, edge, top + maxStrip),
                Rect(w - edge, top, w, top + maxStrip)
            )
        }
        if (w > 0 && h > 0) {
            val portrait = h > w
            if (portrait != lastPortrait) {
                lastPortrait = portrait
                onShapeChange?.invoke(portrait)
            }
        }
    }

    private fun updateGeometry() {
        val cfg = streamConfig
        if (cfg == null || width <= 0 || height <= 0) {
            mapper = null
            return
        }
        val m = CoordinateMapper.create(width.toFloat(), height.toFloat(), cfg.pointWidth.toFloat(), cfg.pointHeight.toFloat())
        mapper = m
        if (m != null) {
            val lp = LayoutParams(m.contentRect.width.toInt(), m.contentRect.height.toInt(), Gravity.CENTER)
            surfaceView.layoutParams = lp
        }
        layoutCursor()
    }

    private fun layoutCursor() {
        val m = mapper
        val shape = cursorShape
        if (streamConfig == null || !cursorVisible || m == null || shape == null) {
            cursorView.visibility = GONE
            return
        }
        val cw = (shape.width * m.contentRect.width).toInt().coerceAtLeast(1)
        val ch = (shape.height * m.contentRect.height).toInt().coerceAtLeast(1)
        val cx = m.contentRect.left + cursorNormX * m.contentRect.width - shape.hotX * cw
        val cy = m.contentRect.top + cursorNormY * m.contentRect.height - shape.hotY * ch
        val lp = cursorView.layoutParams as LayoutParams
        if (lp.width != cw || lp.height != ch) {
            lp.width = cw
            lp.height = ch
            cursorView.layoutParams = lp
        }
        cursorView.translationX = cx
        cursorView.translationY = cy
        cursorView.visibility = VISIBLE
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        if (streamConfig == null) return false
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_HOVER_ENTER || action == MotionEvent.ACTION_HOVER_MOVE) {
            val norm = mapper?.normalized(event.x, event.y) ?: return false
            emit(listOf(InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, norm.x, norm.y)))
            return true
        }
        return super.onHoverEvent(event)
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (streamConfig == null) return false
        if (event.actionMasked == MotionEvent.ACTION_SCROLL) {
            val dx = (event.getAxisValue(MotionEvent.AXIS_HSCROLL) * 32f)
                .coerceIn(-SessionConstants.MAX_SCROLL_DELTA, SessionConstants.MAX_SCROLL_DELTA)
            val dy = (event.getAxisValue(MotionEvent.AXIS_VSCROLL) * 32f)
                .coerceIn(-SessionConstants.MAX_SCROLL_DELTA, SessionConstants.MAX_SCROLL_DELTA)
            if (dx != 0f || dy != 0f) {
                emit(listOf(InputEvent.Scroll(dx, dy)))
                return true
            }
        }
        return super.onGenericMotionEvent(event)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (streamConfig == null) return false
        requestFocus()
        val action = event.actionMasked
        val idx = event.actionIndex
        val toolType = event.getToolType(idx)

        // Stylus (S Pen / USI / active stylus): immediate click/drag/draw with pressure + palm rejection.
        if (toolType == MotionEvent.TOOL_TYPE_STYLUS || toolType == MotionEvent.TOOL_TYPE_ERASER ||
            stylusPointerId != MotionEvent.INVALID_POINTER_ID
        ) {
            return handleStylus(event)
        }

        // Mouse / external pointer clicks.
        if (toolType == MotionEvent.TOOL_TYPE_MOUSE) {
            return handleMouse(event)
        }

        // Palm rejection window after stylus lift.
        if (SystemClock.uptimeMillis() < palmRejectUntilMs) return true

        val count = event.pointerCount
        if (action == MotionEvent.ACTION_DOWN) stopMomentum()

        // 3-finger edit gestures (copy/cut/paste/undo/redo).
        if (count == 3 || threeFingerActive) {
            return handleThreeFinger(event)
        }

        // 2-finger tap (right click), scroll, pinch, rotate.
        if (count == 2 || twoFingerActive) {
            return handleTwoFinger(event)
        }

        // 1-finger TouchInterpreter.
        val timeSec = event.eventTime / 1000.0
        val m = mapper ?: return true
        when (action) {
            MotionEvent.ACTION_DOWN -> {
                primaryPointerId = event.getPointerId(0)
                val pt = PointF(event.x, event.y)
                emit(interpreter.began(pt, m.normalized(pt.x, pt.y), timeSec))
                scheduleHoldIfPending()
            }
            MotionEvent.ACTION_MOVE -> {
                val pIdx = event.findPointerIndex(primaryPointerId)
                if (pIdx >= 0) {
                    val pt = PointF(event.getX(pIdx), event.getY(pIdx))
                    emit(interpreter.moved(pt, m.normalized(pt.x, pt.y), m.pointScale, timeSec))
                }
            }
            MotionEvent.ACTION_UP -> {
                cancelHold()
                primaryPointerId = MotionEvent.INVALID_POINTER_ID
                emit(interpreter.ended(timeSec))
                interpreter.takeFling()?.let { startMomentum(it) }
            }
            MotionEvent.ACTION_CANCEL -> {
                cancelHold()
                primaryPointerId = MotionEvent.INVALID_POINTER_ID
                emit(interpreter.cancelled())
            }
        }
        return true
    }

    private fun handleStylus(event: MotionEvent): Boolean {
        val m = mapper ?: return true
        val action = event.actionMasked
        val btnMask = event.buttonState
        val secondaryTriggered = (btnMask and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0 &&
            (lastStylusButtonMask and MotionEvent.BUTTON_STYLUS_PRIMARY) == 0
        lastStylusButtonMask = btnMask
        if (secondaryTriggered) performStylusAction()

        when (action) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                if (primaryPointerId != MotionEvent.INVALID_POINTER_ID) {
                    primaryPointerId = MotionEvent.INVALID_POINTER_ID
                    cancelHold()
                    emit(interpreter.cancelled())
                }
                val idx = event.actionIndex
                stylusPointerId = event.getPointerId(idx)
                val norm = m.normalized(event.getX(idx), event.getY(idx)) ?: return true
                lastStylusNorm = norm
                emit(listOf(InputEvent.Stylus(PointerPhase.DOWN, norm.x, norm.y, event.getPressure(idx).coerceIn(0f, 1f))))
            }
            MotionEvent.ACTION_MOVE -> {
                val pIdx = event.findPointerIndex(stylusPointerId)
                if (pIdx >= 0) {
                    val out = ArrayList<InputEvent>(event.historySize + 1)
                    for (h in 0 until event.historySize) {
                        val norm = m.normalized(event.getHistoricalX(pIdx, h), event.getHistoricalY(pIdx, h)) ?: continue
                        lastStylusNorm = norm
                        out.add(InputEvent.Stylus(PointerPhase.MOVE, norm.x, norm.y, event.getHistoricalPressure(pIdx, h).coerceIn(0f, 1f)))
                    }
                    m.normalized(event.getX(pIdx), event.getY(pIdx))?.let { norm ->
                        lastStylusNorm = norm
                        out.add(InputEvent.Stylus(PointerPhase.MOVE, norm.x, norm.y, event.getPressure(pIdx).coerceIn(0f, 1f)))
                    }
                    if (out.isNotEmpty()) emit(out)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_CANCEL -> {
                val pIdx = event.findPointerIndex(stylusPointerId)
                val norm = if (pIdx >= 0) m.normalized(event.getX(pIdx), event.getY(pIdx)) ?: lastStylusNorm else lastStylusNorm
                stylusPointerId = MotionEvent.INVALID_POINTER_ID
                palmRejectUntilMs = SystemClock.uptimeMillis() + 250L
                emit(listOf(InputEvent.Stylus(PointerPhase.UP, norm.x, norm.y, 0f)))
            }
        }
        return true
    }

    private fun performStylusAction() {
        when (stylusAction) {
            StylusAction.OFF -> {}
            StylusAction.RIGHT_CLICK -> {
                val x = if (cursorVisible) cursorNormX else lastStylusNorm.x
                val y = if (cursorVisible) cursorNormY else lastStylusNorm.y
                emit(
                    listOf(
                        InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, x, y),
                        InputEvent.Pointer(PointerPhase.DOWN, PointerButton.RIGHT, x, y),
                        InputEvent.Pointer(PointerPhase.UP, PointerButton.RIGHT, x, y)
                    )
                )
            }
            StylusAction.UNDO -> emit(
                listOf(
                    InputEvent.Key(0xE3, true), InputEvent.Key(0x1D, true),
                    InputEvent.Key(0x1D, false), InputEvent.Key(0xE3, false)
                )
            )
        }
    }

    private fun handleMouse(event: MotionEvent): Boolean {
        val m = mapper ?: return true
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val norm = m.normalized(event.x, event.y) ?: return true
                val button = if ((event.buttonState and MotionEvent.BUTTON_SECONDARY) != 0) {
                    PointerButton.RIGHT
                } else {
                    PointerButton.LEFT
                }
                mouseButtonHeld = button
                lastMouseNorm = norm
                emit(
                    listOf(
                        InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, norm.x, norm.y),
                        InputEvent.Pointer(PointerPhase.DOWN, button, norm.x, norm.y)
                    )
                )
            }
            MotionEvent.ACTION_MOVE -> {
                val norm = m.normalized(event.x, event.y) ?: return true
                lastMouseNorm = norm
                emit(listOf(InputEvent.Pointer(PointerPhase.MOVE, mouseButtonHeld ?: PointerButton.NONE, norm.x, norm.y)))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val button = mouseButtonHeld ?: return true
                mouseButtonHeld = null
                val norm = m.normalized(event.x, event.y) ?: lastMouseNorm
                emit(listOf(InputEvent.Pointer(PointerPhase.UP, button, norm.x, norm.y)))
            }
        }
        return true
    }

    private fun handleTwoFinger(event: MotionEvent): Boolean {
        val m = mapper ?: return true
        val action = event.actionMasked
        if (!twoFingerActive) {
            cancelHold()
            primaryPointerId = MotionEvent.INVALID_POINTER_ID
            emit(interpreter.cancelled())
            if (event.pointerCount < 2) return true
            twoFingerActive = true
            twoFingerStartMs = event.eventTime
            twoFingerMoved = false
            twoFingerPinchStarted = false
            twoFingerRotateStarted = false
            twoFingerLastCx = (event.getX(0) + event.getX(1)) / 2f
            twoFingerLastCy = (event.getY(0) + event.getY(1)) / 2f
            twoFingerStartDist = hypot(event.getX(1) - event.getX(0), event.getY(1) - event.getY(0)).coerceAtLeast(1f)
            twoFingerStartAngle = atan2(event.getY(1) - event.getY(0), event.getX(1) - event.getX(0))
            m.normalized(twoFingerLastCx, twoFingerLastCy)?.let { norm ->
                emit(listOf(InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, norm.x, norm.y)))
            }
            return true
        }

        if (action == MotionEvent.ACTION_MOVE && event.pointerCount >= 2) {
            val cx = (event.getX(0) + event.getX(1)) / 2f
            val cy = (event.getY(0) + event.getY(1)) / 2f
            val dist = hypot(event.getX(1) - event.getX(0), event.getY(1) - event.getY(0)).coerceAtLeast(1f)
            val angle = atan2(event.getY(1) - event.getY(0), event.getX(1) - event.getX(0))
            val dCx = cx - twoFingerLastCx
            val dCy = cy - twoFingerLastCy
            val scale = dist / twoFingerStartDist
            val rotRad = angle - twoFingerStartAngle

            if (!twoFingerMoved && (hypot(dCx, dCy) > 8f || kotlin.math.abs(scale - 1f) > 0.08f)) {
                twoFingerMoved = true
                emit(listOf(InputEvent.GestureScroll(0f, 0f, ScrollPhase.BEGAN, MomentumPhase.NONE)))
            }
            if (twoFingerMoved) {
                val limit = SessionConstants.MAX_SCROLL_DELTA
                val dx = (dCx * m.pointScale).coerceIn(-limit, limit)
                val dy = (dCy * m.pointScale).coerceIn(-limit, limit)
                if (dx != 0f || dy != 0f) {
                    emit(listOf(InputEvent.GestureScroll(dx, dy, ScrollPhase.CHANGED, MomentumPhase.NONE)))
                }
                if (!twoFingerPinchStarted && kotlin.math.abs(scale - 1f) > 0.1f) {
                    twoFingerPinchStarted = true
                    emit(listOf(transformTracker.beganPinch()))
                }
                if (twoFingerPinchStarted) {
                    transformTracker.pinch(scale)?.let { emit(listOf(it)) }
                }
                if (!twoFingerRotateStarted && kotlin.math.abs(rotRad) > 0.15f) {
                    twoFingerRotateStarted = true
                    emit(listOf(transformTracker.beganRotation()))
                }
                if (twoFingerRotateStarted) {
                    transformTracker.rotation(rotRad)?.let { emit(listOf(it)) }
                }
            }
            twoFingerLastCx = cx
            twoFingerLastCy = cy
        } else if (action == MotionEvent.ACTION_POINTER_UP || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            val cancelled = action == MotionEvent.ACTION_CANCEL
            if (!twoFingerMoved && !cancelled && event.eventTime - twoFingerStartMs < 350L) {
                m.normalized(twoFingerLastCx, twoFingerLastCy)?.let { norm ->
                    emit(
                        listOf(
                            InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, norm.x, norm.y),
                            InputEvent.Pointer(PointerPhase.DOWN, PointerButton.RIGHT, norm.x, norm.y),
                            InputEvent.Pointer(PointerPhase.UP, PointerButton.RIGHT, norm.x, norm.y)
                        )
                    )
                }
            } else if (twoFingerMoved) {
                emit(listOf(InputEvent.GestureScroll(0f, 0f, if (cancelled) ScrollPhase.CANCELLED else ScrollPhase.ENDED, MomentumPhase.NONE)))
            }
            if (twoFingerPinchStarted) emit(listOf(TransformTracker.endPinch(cancelled)))
            if (twoFingerRotateStarted) emit(listOf(TransformTracker.endRotation(cancelled)))
            twoFingerActive = false
            twoFingerPinchStarted = false
            twoFingerRotateStarted = false
        }
        return true
    }

    private fun handleThreeFinger(event: MotionEvent): Boolean {
        val action = event.actionMasked
        if (!threeFingerActive) {
            if (twoFingerActive) {
                if (twoFingerMoved) emit(listOf(InputEvent.GestureScroll(0f, 0f, ScrollPhase.CANCELLED, MomentumPhase.NONE)))
                twoFingerActive = false
            }
            cancelHold()
            emit(interpreter.cancelled())
            if (event.pointerCount < 3) return true
            threeFingerActive = true
            threeStartCx = (event.getX(0) + event.getX(1) + event.getX(2)) / 3f
            threeStartCy = (event.getY(0) + event.getY(1) + event.getY(2)) / 3f
            threeStartSpread = threeFingerSpread(event, threeStartCx, threeStartCy)
            threeEndSpread = threeStartSpread
            threeTravelDx = 0f
            threeTravelDy = 0f
            return true
        }
        if (action == MotionEvent.ACTION_MOVE && event.pointerCount >= 3) {
            val cx = (event.getX(0) + event.getX(1) + event.getX(2)) / 3f
            val cy = (event.getY(0) + event.getY(1) + event.getY(2)) / 3f
            threeEndSpread = threeFingerSpread(event, cx, cy)
            threeTravelDx = cx - threeStartCx
            threeTravelDy = cy - threeStartCy
        } else if (action == MotionEvent.ACTION_POINTER_UP || action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            if (action != MotionEvent.ACTION_CANCEL) {
                val nowSec = SystemClock.uptimeMillis() / 1000.0
                val g = EditGesture.classify(
                    startSpread = threeStartSpread,
                    endSpread = threeEndSpread,
                    travelDx = threeTravelDx,
                    travelDy = threeTravelDy,
                    previous = lastEditGesture,
                    sincePreviousSeconds = nowSec - lastEditTimeSec,
                    swipeThresholdPx = 80f * resources.displayMetrics.density
                )
                if (g != null) {
                    lastEditGesture = g
                    lastEditTimeSec = nowSec
                    emit(g.keys)
                }
            }
            threeFingerActive = false
        }
        return true
    }

    private fun threeFingerSpread(event: MotionEvent, cx: Float, cy: Float): Float {
        var sum = 0f
        for (i in 0 until 3) sum += hypot(event.getX(i) - cx, event.getY(i) - cy)
        return sum / 3f
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (streamConfig == null) return super.onKeyDown(keyCode, event)
        val usage = AndroidKeyMap.hidUsageForKeyCode(keyCode) ?: return super.onKeyDown(keyCode, event)
        if (event.repeatCount == 0) {
            heldKeys.add(usage)
            emit(shortcuts.key(usage, down = true))
        }
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (streamConfig == null) return super.onKeyUp(keyCode, event)
        val usage = AndroidKeyMap.hidUsageForKeyCode(keyCode) ?: return super.onKeyUp(keyCode, event)
        if (heldKeys.remove(usage)) {
            emit(shortcuts.key(usage, down = false))
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    private fun scheduleHoldIfPending() {
        if (interpreter.state !is TouchInterpreter.State.Pending || holdRunnable != null) return
        val r = Runnable {
            holdRunnable = null
            emit(interpreter.holdElapsed(SystemClock.uptimeMillis() / 1000.0))
        }
        holdRunnable = r
        mainHandler.postDelayed(r, (interpreter.holdDelaySeconds * 1000).toLong())
    }

    private fun cancelHold() {
        holdRunnable?.let { mainHandler.removeCallbacks(it) }
        holdRunnable = null
    }

    private fun startMomentum(velocity: PointF) {
        stopMomentum()
        if (hypot(velocity.x, velocity.y) <= 90f) return
        momentumVx = velocity.x
        momentumVy = velocity.y
        momentumStarted = false
        momentumActive = true
        momentumLastNs = System.nanoTime()
        Choreographer.getInstance().postFrameCallback(momentumCallback)
    }

    private fun stopMomentum() {
        if (!momentumActive) return
        momentumActive = false
        Choreographer.getInstance().removeFrameCallback(momentumCallback)
        if (momentumStarted) {
            emit(listOf(InputEvent.GestureScroll(0f, 0f, ScrollPhase.NONE, MomentumPhase.END)))
        }
        momentumStarted = false
    }

    private fun resetTouches() {
        stopMomentum()
        cancelHold()
        primaryPointerId = MotionEvent.INVALID_POINTER_ID
        stylusPointerId = MotionEvent.INVALID_POINTER_ID
        twoFingerActive = false
        threeFingerActive = false
        mouseButtonHeld?.let { btn ->
            mouseButtonHeld = null
            emit(listOf(InputEvent.Pointer(PointerPhase.UP, btn, lastMouseNorm.x, lastMouseNorm.y)))
        }
        if (heldKeys.isNotEmpty()) {
            emit(heldKeys.flatMap { shortcuts.key(it, down = false) })
            heldKeys.clear()
            shortcuts.reset()
        }
        emit(interpreter.cancelled())
    }

    private fun emit(events: List<InputEvent>) {
        for (event in events) {
            when (event) {
                is InputEvent.Pointer -> {
                    localPointerUntilMs = SystemClock.uptimeMillis() + 150L
                    cursorNormX = event.x
                    cursorNormY = event.y
                    layoutCursor()
                }
                is InputEvent.Stylus -> {
                    localPointerUntilMs = SystemClock.uptimeMillis() + 150L
                    cursorNormX = event.x
                    cursorNormY = event.y
                    layoutCursor()
                }
                else -> {}
            }
            onInput?.invoke(event)
        }
    }
}
