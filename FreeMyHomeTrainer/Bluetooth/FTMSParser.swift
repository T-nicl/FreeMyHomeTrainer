import Foundation

/// UUID Bluetooth des services et caractéristiques utilisés.
enum GATT {
    static let fitnessMachineService = "1826"
    static let indoorBikeData = "2AD2"
    static let controlPoint = "2AD9"
    static let machineStatus = "2ADA"
    static let supportedPowerRange = "2AD8"

    static let heartRateService = "180D"
    static let heartRateMeasurement = "2A37"
}

/// Mesures décodées d'une trame Indoor Bike Data (FTMS 0x2AD2).
struct IndoorBikeData: Equatable, Sendable {
    var speedKmh: Double?
    var cadence: Double?
    var totalDistance: Int?
    var power: Int?
    var heartRate: Int?
}

/// Lecture little-endian séquentielle d'une trame.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func s16() -> Int16? { u16().map { Int16(bitPattern: $0) } }

    mutating func u24() -> UInt32? {
        guard remaining >= 3 else { return nil }
        defer { offset += 3 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    }

    mutating func skip(_ n: Int) { offset = min(offset + n, bytes.count) }
}

enum FTMSParser {
    /// Décode une trame Indoor Bike Data selon ses flags (spécification FTMS §4.9).
    static func parseIndoorBikeData(_ data: Data) -> IndoorBikeData? {
        var r = ByteReader(data)
        guard let flags = r.u16() else { return nil }
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }

        var out = IndoorBikeData()
        // Bit 0 « More Data » inversé : 0 => vitesse instantanée présente.
        if !has(0) { out.speedKmh = r.u16().map { Double($0) / 100 } }
        if has(1) { r.skip(2) }                                          // vitesse moyenne
        if has(2) { out.cadence = r.u16().map { Double($0) / 2 } }      // résolution 0,5 rpm
        if has(3) { r.skip(2) }                                          // cadence moyenne
        if has(4) { out.totalDistance = r.u24().map { Int($0) } }
        if has(5) { r.skip(2) }                                          // niveau de résistance
        if has(6) { out.power = r.s16().map { Int($0) } }
        if has(7) { r.skip(2) }                                          // puissance moyenne
        if has(8) { r.skip(5) }                                          // énergie dépensée
        if has(9) { out.heartRate = r.u8().map { Int($0) } }
        return out
    }

    /// Plage de puissance supportée (0x2AD8) : min, max, incrément.
    static func parsePowerRange(_ data: Data) -> ClosedRange<Int>? {
        var r = ByteReader(data)
        guard let lo = r.s16(), let hi = r.s16(), lo <= hi else { return nil }
        return Int(lo)...Int(hi)
    }

    /// Fréquence cardiaque (0x2A37) : bit 0 des flags = format 16 bits.
    static func parseHeartRate(_ data: Data) -> Int? {
        var r = ByteReader(data)
        guard let flags = r.u8() else { return nil }
        if flags & 0x01 != 0 { return r.u16().map(Int.init) }
        return r.u8().map(Int.init)
    }

    /// Réponse du Control Point : 0x80, opcode de la requête, code résultat (0x01 = succès).
    static func parseControlPointResponse(_ data: Data) -> (opcode: UInt8, success: Bool)? {
        var r = ByteReader(data)
        guard r.u8() == 0x80, let op = r.u8(), let result = r.u8() else { return nil }
        return (op, result == 0x01)
    }
}

/// Commandes du Control Point FTMS.
enum FTMSCommand: Equatable, Sendable {
    case requestControl
    case start
    case setTargetPower(Int)
    /// Pente en %, pour un mode « libre » simulé.
    case setSimulation(gradePercent: Double)

    var opcode: UInt8 {
        switch self {
        case .requestControl: 0x00
        case .setTargetPower: 0x05
        case .start: 0x07
        case .setSimulation: 0x11
        }
    }

    var data: Data {
        var bytes: [UInt8] = [opcode]
        switch self {
        case .requestControl, .start:
            break
        case .setTargetPower(let watts):
            let w = Int16(clamping: watts)
            bytes += [UInt8(truncatingIfNeeded: w), UInt8(truncatingIfNeeded: w >> 8)]
        case .setSimulation(let grade):
            let g = Int16(clamping: Int((grade * 100).rounded()))   // résolution 0,01 %
            bytes += [0, 0]                                           // vent (0,001 m/s)
            bytes += [UInt8(truncatingIfNeeded: g), UInt8(truncatingIfNeeded: g >> 8)]
            bytes += [40, 51]                                         // Crr 0,0040 ; CwA 0,51 kg/m
        }
        return Data(bytes)
    }
}
