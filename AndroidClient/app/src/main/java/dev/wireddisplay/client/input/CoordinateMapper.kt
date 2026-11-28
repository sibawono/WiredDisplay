package dev.wireddisplay.client.input

/** Aspect-fit geometry mapper matching Shared/Geometry/CoordinateMapper.swift. */
data class PointF(val x: Float, val y: Float)

data class RectF(val left: Float, val top: Float, val width: Float, val height: Float) {
    val right: Float get() = left + width
    val bottom: Float get() = top + height
}

class CoordinateMapper private constructor(
    val viewWidth: Float,
    val viewHeight: Float,
    val displayWidth: Float,
    val displayHeight: Float,
    val contentRect: RectF
) {
    val pointScale: Float
        get() = if (contentRect.width > 0f) displayWidth / contentRect.width else 1f

    /** Maps a view coordinate into normalized [0, 1] display space, or null in letterbox bars. */
    fun normalized(viewX: Float, viewY: Float): PointF? {
        if (!viewX.isFinite() || !viewY.isFinite()) return null
        if (viewX < contentRect.left || viewX > contentRect.right ||
            viewY < contentRect.top || viewY > contentRect.bottom
        ) {
            return null
        }
        val nx = ((viewX - contentRect.left) / contentRect.width).coerceIn(0f, 1f)
        val ny = ((viewY - contentRect.top) / contentRect.height).coerceIn(0f, 1f)
        return PointF(nx, ny)
    }

    companion object {
        fun create(viewWidth: Float, viewHeight: Float, displayWidth: Float, displayHeight: Float): CoordinateMapper? {
            if (!viewWidth.isFinite() || !viewHeight.isFinite() ||
                !displayWidth.isFinite() || !displayHeight.isFinite() ||
                viewWidth <= 0f || viewHeight <= 0f || displayWidth <= 0f || displayHeight <= 0f
            ) {
                return null
            }
            val scale = minOf(viewWidth / displayWidth, viewHeight / displayHeight)
            val w = displayWidth * scale
            val h = displayHeight * scale
            if (w <= 0f || h <= 0f || !w.isFinite() || !h.isFinite()) return null
            val rect = RectF((viewWidth - w) / 2f, (viewHeight - h) / 2f, w, h)
            return CoordinateMapper(viewWidth, viewHeight, displayWidth, displayHeight, rect)
        }
    }
}
