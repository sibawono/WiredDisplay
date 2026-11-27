package dev.wireddisplay.client.input

import android.view.KeyEvent
import dev.wireddisplay.client.session.InputEvent

/** Remaps Control to Command for shortcuts Android/iPadOS reserve, matching Shared/Session/ShortcutRemapper.swift. */
class ShortcutRemapper {
    private data class Rule(val shift: Boolean?, val option: Boolean?)

    private val held = HashSet<Int>()
    private var controlAsCommand = false

    fun key(usage: Int, down: Boolean): List<InputEvent> {
        if (down) return press(usage)
        held.remove(usage)
        if (controlAsCommand && usage in CONTROLS) {
            if (held.any { it in CONTROLS }) return emptyList()
            controlAsCommand = false
            return listOf(InputEvent.Key(COMMAND, false))
        }
        return listOf(InputEvent.Key(usage, false))
    }

    fun reset() {
        held.clear()
        controlAsCommand = false
    }

    private fun press(usage: Int): List<InputEvent> {
        held.add(usage)
        if (controlAsCommand && usage in CONTROLS) return emptyList()
        val rule = REMAPPED[usage]
        if (controlAsCommand || usage in ALL_MODIFIERS || rule == null ||
            held.none { it in CONTROLS } || held.any { it in COMMANDS }
        ) {
            return listOf(InputEvent.Key(usage, true))
        }
        val shiftHeld = held.any { it in SHIFTS }
        val optionHeld = held.any { it in OPTIONS }
        if (rule.shift != null && rule.shift != shiftHeld) return listOf(InputEvent.Key(usage, true))
        if (rule.option != null && rule.option != optionHeld) return listOf(InputEvent.Key(usage, true))
        controlAsCommand = true
        val releaseControls = held.filter { it in CONTROLS }.sorted().map { InputEvent.Key(it, false) }
        return releaseControls + listOf(InputEvent.Key(COMMAND, true), InputEvent.Key(usage, true))
    }

    companion object {
        private val CONTROLS = setOf(0xE0, 0xE4)
        private val SHIFTS = setOf(0xE1, 0xE5)
        private val OPTIONS = setOf(0xE2, 0xE6)
        private val COMMANDS = setOf(0xE3, 0xE7)
        private val ALL_MODIFIERS = CONTROLS + SHIFTS + OPTIONS + COMMANDS
        private const val COMMAND = 0xE3

        private val REMAPPED = mapOf(
            0x2B to Rule(shift = null, option = false),
            0x35 to Rule(shift = null, option = false),
            0x2C to Rule(shift = false, option = null),
            0x20 to Rule(shift = true, option = false),
            0x21 to Rule(shift = true, option = false),
            0x22 to Rule(shift = true, option = false),
            0x0B to Rule(shift = false, option = null),
            0x07 to Rule(shift = false, option = true),
            0x29 to Rule(shift = false, option = true)
        )
    }
}

/** Maps Android KeyEvent keycodes and soft-keyboard characters to USB HID Keyboard/Keypad usages (page 0x07). */
object AndroidKeyMap {
    private val keyCodeToHid = mapOf(
        KeyEvent.KEYCODE_A to 0x04, KeyEvent.KEYCODE_B to 0x05, KeyEvent.KEYCODE_C to 0x06,
        KeyEvent.KEYCODE_D to 0x07, KeyEvent.KEYCODE_E to 0x08, KeyEvent.KEYCODE_F to 0x09,
        KeyEvent.KEYCODE_G to 0x0A, KeyEvent.KEYCODE_H to 0x0B, KeyEvent.KEYCODE_I to 0x0C,
        KeyEvent.KEYCODE_J to 0x0D, KeyEvent.KEYCODE_K to 0x0E, KeyEvent.KEYCODE_L to 0x0F,
        KeyEvent.KEYCODE_M to 0x10, KeyEvent.KEYCODE_N to 0x11, KeyEvent.KEYCODE_O to 0x12,
        KeyEvent.KEYCODE_P to 0x13, KeyEvent.KEYCODE_Q to 0x14, KeyEvent.KEYCODE_R to 0x15,
        KeyEvent.KEYCODE_S to 0x16, KeyEvent.KEYCODE_T to 0x17, KeyEvent.KEYCODE_U to 0x18,
        KeyEvent.KEYCODE_V to 0x19, KeyEvent.KEYCODE_W to 0x1A, KeyEvent.KEYCODE_X to 0x1B,
        KeyEvent.KEYCODE_Y to 0x1C, KeyEvent.KEYCODE_Z to 0x1D,
        KeyEvent.KEYCODE_1 to 0x1E, KeyEvent.KEYCODE_2 to 0x1F, KeyEvent.KEYCODE_3 to 0x20,
        KeyEvent.KEYCODE_4 to 0x21, KeyEvent.KEYCODE_5 to 0x22, KeyEvent.KEYCODE_6 to 0x23,
        KeyEvent.KEYCODE_7 to 0x24, KeyEvent.KEYCODE_8 to 0x25, KeyEvent.KEYCODE_9 to 0x26,
        KeyEvent.KEYCODE_0 to 0x27,
        KeyEvent.KEYCODE_ENTER to 0x28, KeyEvent.KEYCODE_ESCAPE to 0x29,
        KeyEvent.KEYCODE_DEL to 0x2A, KeyEvent.KEYCODE_TAB to 0x2B, KeyEvent.KEYCODE_SPACE to 0x2C,
        KeyEvent.KEYCODE_MINUS to 0x2D, KeyEvent.KEYCODE_EQUALS to 0x2E,
        KeyEvent.KEYCODE_LEFT_BRACKET to 0x2F, KeyEvent.KEYCODE_RIGHT_BRACKET to 0x30,
        KeyEvent.KEYCODE_BACKSLASH to 0x31, KeyEvent.KEYCODE_SEMICOLON to 0x33,
        KeyEvent.KEYCODE_APOSTROPHE to 0x34, KeyEvent.KEYCODE_GRAVE to 0x35,
        KeyEvent.KEYCODE_COMMA to 0x36, KeyEvent.KEYCODE_PERIOD to 0x37, KeyEvent.KEYCODE_SLASH to 0x38,
        KeyEvent.KEYCODE_CAPS_LOCK to 0x39,
        KeyEvent.KEYCODE_F1 to 0x3A, KeyEvent.KEYCODE_F2 to 0x3B, KeyEvent.KEYCODE_F3 to 0x3C,
        KeyEvent.KEYCODE_F4 to 0x3D, KeyEvent.KEYCODE_F5 to 0x3E, KeyEvent.KEYCODE_F6 to 0x3F,
        KeyEvent.KEYCODE_F7 to 0x40, KeyEvent.KEYCODE_F8 to 0x41, KeyEvent.KEYCODE_F9 to 0x42,
        KeyEvent.KEYCODE_F10 to 0x43, KeyEvent.KEYCODE_F11 to 0x44, KeyEvent.KEYCODE_F12 to 0x45,
        KeyEvent.KEYCODE_INSERT to 0x49, KeyEvent.KEYCODE_MOVE_HOME to 0x4A,
        KeyEvent.KEYCODE_PAGE_UP to 0x4B, KeyEvent.KEYCODE_FORWARD_DEL to 0x4C,
        KeyEvent.KEYCODE_MOVE_END to 0x4D, KeyEvent.KEYCODE_PAGE_DOWN to 0x4E,
        KeyEvent.KEYCODE_DPAD_RIGHT to 0x4F, KeyEvent.KEYCODE_DPAD_LEFT to 0x50,
        KeyEvent.KEYCODE_DPAD_DOWN to 0x51, KeyEvent.KEYCODE_DPAD_UP to 0x52,
        KeyEvent.KEYCODE_CTRL_LEFT to 0xE0, KeyEvent.KEYCODE_SHIFT_LEFT to 0xE1,
        KeyEvent.KEYCODE_ALT_LEFT to 0xE2, KeyEvent.KEYCODE_META_LEFT to 0xE3,
        KeyEvent.KEYCODE_CTRL_RIGHT to 0xE4, KeyEvent.KEYCODE_SHIFT_RIGHT to 0xE5,
        KeyEvent.KEYCODE_ALT_RIGHT to 0xE6, KeyEvent.KEYCODE_META_RIGHT to 0xE7
    )

    fun hidUsageForKeyCode(keyCode: Int): Int? = keyCodeToHid[keyCode]

    /** Converts a typed ASCII character from an on-screen keyboard into HID key press/release events. */
    fun eventsForCharacter(ch: Char): List<InputEvent> {
        val (usage, shift) = when (ch) {
            in 'a'..'z' -> (0x04 + (ch - 'a')) to false
            in 'A'..'Z' -> (0x04 + (ch - 'A')) to true
            in '1'..'9' -> (0x1E + (ch - '1')) to false
            '0' -> 0x27 to false
            '\n', '\r' -> 0x28 to false
            '\t' -> 0x2B to false
            ' ' -> 0x2C to false
            '-' -> 0x2D to false; '_' -> 0x2D to true
            '=' -> 0x2E to false; '+' -> 0x2E to true
            '[' -> 0x2F to false; '{' -> 0x2F to true
            ']' -> 0x30 to false; '}' -> 0x30 to true
            '\\' -> 0x31 to false; '|' -> 0x31 to true
            ';' -> 0x33 to false; ':' -> 0x33 to true
            '\'' -> 0x34 to false; '"' -> 0x34 to true
            '`' -> 0x35 to false; '~' -> 0x35 to true
            ',' -> 0x36 to false; '<' -> 0x36 to true
            '.' -> 0x37 to false; '>' -> 0x37 to true
            '/' -> 0x38 to false; '?' -> 0x38 to true
            '!' -> 0x1E to true; '@' -> 0x1F to true; '#' -> 0x20 to true
            '$' -> 0x21 to true; '%' -> 0x22 to true; '^' -> 0x23 to true
            '&' -> 0x24 to true; '*' -> 0x25 to true; '(' -> 0x26 to true; ')' -> 0x27 to true
            else -> return emptyList()
        }
        return if (shift) {
            listOf(
                InputEvent.Key(0xE1, true),
                InputEvent.Key(usage, true),
                InputEvent.Key(usage, false),
                InputEvent.Key(0xE1, false)
            )
        } else {
            listOf(InputEvent.Key(usage, true), InputEvent.Key(usage, false))
        }
    }
}
