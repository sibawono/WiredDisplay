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

    /// Key usage -> whether Shift must be held (nil: either way).
    static let remapped: [UInt16: Bool?] = [
        0x2B: nil,    // Tab: app switcher (Shift: backwards)
        0x35: nil,    // `: windows of the current app
        0x2C: false,  // Space: Spotlight
        0x20: true, 0x21: true, 0x22: true, // Shift-3/4/5: screenshots
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
        guard !controlAsCommand, KeyMap.modifier(forUsage: usage) == nil, let needsShift = Self.remapped[usage],
              !held.isDisjoint(with: Self.controls), held.isDisjoint(with: Self.commands), held.isDisjoint(with: Self.options)
        else { return [.key(usage: usage, down: true)] }
        let shiftHeld = !held.isDisjoint(with: Self.shifts)
        if let needsShift, needsShift != shiftHeld { return [.key(usage: usage, down: true)] }
        controlAsCommand = true
        let releaseControl = held.intersection(Self.controls).sorted().map { InputEvent.key(usage: $0, down: false) }
        return releaseControl + [.key(usage: Self.command, down: true), .key(usage: usage, down: true)]
    }
}
