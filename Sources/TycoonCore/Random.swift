/// Детерминированный генератор случайных чисел (SplitMix64).
/// Один и тот же seed даёт одну и ту же партию: удобно для отладки,
/// симуляций и Bluetooth-режима, где кубики бросает только хост.
public struct SplitMix64: RandomNumberGenerator, Codable, Sendable, Equatable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Бросок двух кубиков. Всегда два отдельных значения 1...6,
/// а не одно число 2...12, иначе ломается распределение сумм.
public struct DiceRoll: Codable, Sendable, Equatable, Hashable {
    public let d1: Int
    public let d2: Int

    public init(_ d1: Int, _ d2: Int) {
        precondition((1...6).contains(d1) && (1...6).contains(d2), "Значение кубика должно быть от 1 до 6")
        self.d1 = d1
        self.d2 = d2
    }

    public var total: Int { d1 + d2 }
    public var isDouble: Bool { d1 == d2 }

    /// Все 36 комбинаций — «мешок» для режима ровных кубиков.
    public static let allCombinations: [DiceRoll] =
        (1...6).flatMap { a in (1...6).map { b in DiceRoll(a, b) } }
}
