/// iPadOS keeps Command-Tab, Command-Space and Command-Shift-3/4/5 for itself,
/// even with key-command priority (verified on hardware, D-030). So on the
/// iPad keyboard Control stands in for Command for those shortcuts: the Mac
/// receives Command instead, and Control keeps acting as Command until it is
/// released, so holding Control and pressing Tab repeatedly walks the app
/// switcher like Command-Tab on a Mac. Pure, so it can be unit-tested.
public struct ShortcutRemapper: Sendable {
    static let controls: Set<UInt16> = [0xE0, 0xE4]
    static let shifts: Set<UInt16> = [0xE1, 0xE5]
    static let options: Set<UInt16> = [0xE2, 0xE6]
    static let commands: Set<UInt16> = [0xE3, 0xE7]
    static let command: UInt16 = 0xE3

    struct Rule: Sendable {
        /// nil = either way, true = must be held, false = must not be held.
        let shift: Bool?
        let option: Bool?
    }

    /// Key usage -> modifier requirements for Control -> Command remapping.
    static let remapped: [UInt16: Rule] = [
        0x2B: Rule(shift: nil, option: false),   // ⌃Tab / ⌃⇧Tab -> ⌘Tab / ⌘⇧Tab (app switcher)
        0x35: Rule(shift: nil, option: false),   // ⌃` / ⌃⇧` -> ⌘` / ⌘⇧` (windows of current app)
        0x2C: Rule(shift: false, option: nil),   // ⌃Space / ⌃⌥Space -> ⌘Space / ⌘⌥Space (Spotlight / Finder Search)
        0x20: Rule(shift: true, option: false),  // ⌃⇧3 -> ⌘⇧3 (screenshot)
        0x21: Rule(shift: true, option: false),  // ⌃⇧4 -> ⌘⇧4 (screenshot)
        0x22: Rule(shift: true, option: false),  // ⌃⇧5 -> ⌘⇧5 (screenshot)
        0x0B: Rule(shift: false, option: nil),   // ⌃H / ⌃⌥H -> ⌘H / ⌘⌥H (Hide app / Hide others; iPadOS steals ⌘H)
        0x07: Rule(shift: false, option: true),  // ⌃⌥D -> ⌘⌥D (Show/Hide Dock; iPadOS steals ⌘⌥D)
        0x29: Rule(shift: false, option: true),  // ⌃⌥Esc -> ⌘⌥Esc (Force Quit)
    ]

    private var held = Set<UInt16>()
    private var controlAsCommand = false

    public init() {}

    public var isRemapping: Bool { controlAsCommand }

    public mutating func key(usage: UInt16, down: Bool) -> [InputEvent] {
        if down { return press(usage) }
        held.remove(usage)
        if controlAsCommand, Self.controls.contains(usage) {
            guard held.isDisjoint(with: Self.controls) else { return [] } // the other Control is still down
            controlAsCommand = false
            return [.key(usage: Self.command, down: false)]
        }
        return [.key(usage: usage, down: false)]
    }

    /// Everything was released (disconnect, view reset).
    public mutating func reset() {
        held.removeAll()
        controlAsCommand = false
    }

    private mutating func press(_ usage: UInt16) -> [InputEvent] {
        held.insert(usage)
        if controlAsCommand, Self.controls.contains(usage) { return [] }
        guard !controlAsCommand, KeyMap.modifier(forUsage: usage) == nil, let rule = Self.remapped[usage],
              !held.isDisjoint(with: Self.controls), held.isDisjoint(with: Self.commands)
        else { return [.key(usage: usage, down: true)] }
        let shiftHeld = !held.isDisjoint(with: Self.shifts)
        let optionHeld = !held.isDisjoint(with: Self.options)
        if let needsShift = rule.shift, needsShift != shiftHeld { return [.key(usage: usage, down: true)] }
        if let needsOption = rule.option, needsOption != optionHeld { return [.key(usage: usage, down: true)] }
        controlAsCommand = true
        let releaseControl = held.intersection(Self.controls).sorted().map { InputEvent.key(usage: $0, down: false) }
        return releaseControl + [.key(usage: Self.command, down: true), .key(usage: usage, down: true)]
    }
}
