package dev.wireddisplay.client.input

import dev.wireddisplay.client.session.InputEvent
import dev.wireddisplay.client.session.MomentumPhase
import dev.wireddisplay.client.session.PointerButton
import dev.wireddisplay.client.session.PointerPhase
import dev.wireddisplay.client.session.ScrollPhase
import dev.wireddisplay.client.session.SessionConstants
import kotlin.math.abs
import kotlin.math.hypot

/** One-finger touch state machine matching Shared/Session/TouchInterpreter.swift (D-026). */
class TouchInterpreter(
    val slopPx: Float = 18f,
    val holdDelaySeconds: Double = 0.35
) {
    sealed class State {
        object Idle : State()
        data class Pending(val start: PointF, val startTime: Double) : State()
        data class Scrolling(val last: PointF) : State()
        object Dragging : State()
    }

    private data class Sample(val time: Double, val point: PointF)

    var state: State = State.Idle
        private set
    private var fling: PointF? = null
    private var lastNormalized = PointF(0f, 0f)
    private var startNormalized = PointF(0f, 0f)
    private val samples = ArrayList<Sample>()
    private var scale = 1f

    fun takeFling(): PointF? {
        val f = fling
        fling = null
        return f
    }

    fun began(viewPoint: PointF, normalized: PointF?, timeSeconds: Double): List<InputEvent> {
        if (state != State.Idle || normalized == null) return emptyList()
        startNormalized = normalized
        lastNormalized = normalized
        fling = null
        samples.clear()
        samples.add(Sample(timeSeconds, viewPoint))
        state = State.Pending(viewPoint, timeSeconds)
        return emptyList()
    }

    fun moved(viewPoint: PointF, normalized: PointF?, pointScale: Float, timeSeconds: Double): List<InputEvent> {
        scale = pointScale
        return when (val s = state) {
            is State.Pending -> {
                if (hypot(viewPoint.x - s.start.x, viewPoint.y - s.start.y) <= slopPx) return emptyList()
                state = State.Scrolling(viewPoint)
                record(viewPoint, timeSeconds)
                val events = ArrayList<InputEvent>(3)
                events.add(InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, startNormalized.x, startNormalized.y))
                events.add(InputEvent.GestureScroll(0f, 0f, ScrollPhase.BEGAN, MomentumPhase.NONE))
                events.addAll(scrollDelta(s.start, viewPoint))
                events
            }
            is State.Scrolling -> {
                state = State.Scrolling(viewPoint)
                record(viewPoint, timeSeconds)
                scrollDelta(s.last, viewPoint)
            }
            State.Dragging -> {
                if (normalized == null) return emptyList()
                lastNormalized = normalized
                listOf(InputEvent.Pointer(PointerPhase.MOVE, PointerButton.LEFT, normalized.x, normalized.y))
            }
            State.Idle -> emptyList()
        }
    }

    fun holdElapsed(timeSeconds: Double): List<InputEvent> {
        val s = state as? State.Pending ?: return emptyList()
        if (timeSeconds - s.startTime < holdDelaySeconds - 0.001) return emptyList()
        state = State.Dragging
        return listOf(
            InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, startNormalized.x, startNormalized.y),
            InputEvent.Pointer(PointerPhase.DOWN, PointerButton.LEFT, startNormalized.x, startNormalized.y)
        )
    }

    fun ended(timeSeconds: Double): List<InputEvent> {
        val current = state
        state = State.Idle
        return when (current) {
            is State.Pending -> listOf(
                InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, startNormalized.x, startNormalized.y),
                InputEvent.Pointer(PointerPhase.DOWN, PointerButton.LEFT, startNormalized.x, startNormalized.y),
                InputEvent.Pointer(PointerPhase.UP, PointerButton.LEFT, startNormalized.x, startNormalized.y)
            )
            is State.Scrolling -> {
                fling = releaseVelocity(timeSeconds)
                listOf(InputEvent.GestureScroll(0f, 0f, ScrollPhase.ENDED, MomentumPhase.NONE))
            }
            State.Dragging -> listOf(
                InputEvent.Pointer(PointerPhase.UP, PointerButton.LEFT, lastNormalized.x, lastNormalized.y)
            )
            State.Idle -> emptyList()
        }
    }

    fun cancelled(): List<InputEvent> {
        val current = state
        state = State.Idle
        return when (current) {
            is State.Scrolling -> listOf(InputEvent.GestureScroll(0f, 0f, ScrollPhase.CANCELLED, MomentumPhase.NONE))
            State.Dragging -> listOf(
                InputEvent.Pointer(PointerPhase.UP, PointerButton.LEFT, lastNormalized.x, lastNormalized.y)
            )
            else -> emptyList()
        }
    }

    private fun scrollDelta(from: PointF, to: PointF): List<InputEvent> {
        val limit = SessionConstants.MAX_SCROLL_DELTA
        val dx = ((to.x - from.x) * scale).coerceIn(-limit, limit)
        val dy = ((to.y - from.y) * scale).coerceIn(-limit, limit)
        if (dx == 0f && dy == 0f) return emptyList()
        return listOf(InputEvent.GestureScroll(dx, dy, ScrollPhase.CHANGED, MomentumPhase.NONE))
    }

    private fun record(point: PointF, time: Double) {
        samples.add(Sample(time, point))
        samples.removeAll { time - it.time > 0.1 }
    }

    private fun releaseVelocity(time: Double): PointF {
        val first = samples.firstOrNull() ?: return PointF(0f, 0f)
        val last = samples.lastOrNull() ?: return PointF(0f, 0f)
        if (time - last.time >= 0.05 || last.time - first.time <= 0.005) return PointF(0f, 0f)
        val dt = (last.time - first.time).toFloat()
        return PointF((last.point.x - first.point.x) / dt * scale, (last.point.y - first.point.y) / dt * scale)
    }
}

enum class EditGesture {
    COPY, CUT, PASTE, UNDO, REDO;

    val keys: List<InputEvent>
        get() {
            val command = 0xE3
            val shift = 0xE1
            val (letter, mods) = when (this) {
                COPY -> 0x06 to listOf(command)
                CUT -> 0x1B to listOf(command)
                PASTE -> 0x19 to listOf(command)
                UNDO -> 0x1D to listOf(command)
                REDO -> 0x1D to listOf(command, shift)
            }
            return mods.map { InputEvent.Key(it, true) } +
                listOf(InputEvent.Key(letter, true), InputEvent.Key(letter, false)) +
                mods.reversed().map { InputEvent.Key(it, false) }
        }

    companion object {
        fun classify(
            startSpread: Float,
            endSpread: Float,
            travelDx: Float,
            travelDy: Float,
            previous: EditGesture?,
            sincePreviousSeconds: Double,
            swipeThresholdPx: Float = 120f
        ): EditGesture? {
            if (startSpread <= 1f) return null
            val ratio = endSpread / startSpread
            if (abs(travelDx) > swipeThresholdPx && abs(travelDx) > abs(travelDy) * 1.5f &&
                ratio > 0.75f && ratio < 1.33f
            ) {
                return if (travelDx < 0f) UNDO else REDO
            }
            if (ratio < 0.7f) {
                return if (previous == COPY && sincePreviousSeconds < 1.5) CUT else COPY
            }
            if (ratio > 1.4f) return PASTE
            return null
        }
    }
}

class TransformTracker {
    private var lastScale = 1f
    private var lastRotationRad = 0f

    fun beganPinch(): InputEvent {
        lastScale = 1f
        return InputEvent.Magnify(0f, ScrollPhase.BEGAN)
    }

    fun beganRotation(): InputEvent {
        lastRotationRad = 0f
        return InputEvent.Rotate(0f, ScrollPhase.BEGAN)
    }

    fun pinch(scale: Float): InputEvent? {
        if (scale <= 0f || !scale.isFinite()) return null
        val limit = SessionConstants.MAX_MAGNIFY_DELTA
        val delta = (scale - lastScale).coerceIn(-limit, limit)
        lastScale = scale
        return if (delta == 0f) null else InputEvent.Magnify(delta, ScrollPhase.CHANGED)
    }

    fun rotation(radians: Float): InputEvent? {
        if (!radians.isFinite()) return null
        val limit = SessionConstants.MAX_ROTATE_DELTA
        val degrees = (-(radians - lastRotationRad) * 180f / Math.PI.toFloat()).coerceIn(-limit, limit)
        lastRotationRad = radians
        return if (degrees == 0f) null else InputEvent.Rotate(degrees, ScrollPhase.CHANGED)
    }

    companion object {
        fun endPinch(cancelled: Boolean): InputEvent =
            InputEvent.Magnify(0f, if (cancelled) ScrollPhase.CANCELLED else ScrollPhase.ENDED)

        fun endRotation(cancelled: Boolean): InputEvent =
            InputEvent.Rotate(0f, if (cancelled) ScrollPhase.CANCELLED else ScrollPhase.ENDED)
    }
}
