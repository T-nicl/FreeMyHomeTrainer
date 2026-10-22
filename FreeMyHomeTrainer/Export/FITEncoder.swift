import Foundation

/// Données nécessaires pour produire un fichier .FIT d'activité.
struct FITActivity: Sendable {
    var startDate: Date
    var endDate: Date
    var ftp: Int
    var samples: [Sample]
    var laps: [Lap]
}

/// Encodeur FIT minimal pour une activité vélo d'intérieur (protocole FIT 2.0).
/// Messages écrits : file_id, event, record (1 Hz), lap, session, activity.
enum FITEncoder {
    /// Époque FIT : 31/12/1989 00:00 UTC.
    static let epochOffset: TimeInterval = 631_065_600

    static func fitTime(_ date: Date) -> UInt64 {
        UInt64(max(date.timeIntervalSince1970 - epochOffset, 0).rounded())
    }

    static func encode(_ activity: FITActivity) -> Data {
        var w = FITWriter()
        let start = fitTime(activity.startDate)
        let end = fitTime(activity.endDate)
        let all = ActivityMetrics(samples: activity.samples, ftp: activity.ftp)
        let timerTime = activity.laps.reduce(0) { $0 + $1.timerTime }

        // file_id
        w.define(local: 0, global: 0, fields: [
            (0, .enum8), (1, .uint16), (2, .uint16), (3, .uint32z), (4, .uint32),
        ])
        w.write(local: 0, [4, 255, 1, 1_000_001, start])   // activité, fabricant « development »

        // event (timer start / stop)
        w.define(local: 1, global: 21, fields: [(253, .uint32), (0, .enum8), (1, .enum8)])
        w.write(local: 1, [start, 0, 0])

        // record
        w.define(local: 2, global: 20, fields: [
            (253, .uint32), (3, .uint8), (4, .uint8), (7, .uint16), (6, .uint16), (5, .uint32),
        ])
        var previous: Sample?
        for s in activity.samples {
            // Un trou dans les horodatages = une pause : on l'indique par des events timer.
            if let p = previous, s.timestamp.timeIntervalSince(p.timestamp) > 1.5 {
                w.write(local: 1, [fitTime(p.timestamp), 0, 4])   // timer stop_all
                w.write(local: 1, [fitTime(s.timestamp), 0, 0])   // timer start
            }
            w.write(local: 2, [
                fitTime(s.timestamp),
                s.heartRate.map { UInt64(clamping: $0) },
                s.cadence.map { UInt64(clamping: $0) },
                s.power.map { UInt64(clamping: $0) },
                s.speed.map { UInt64(clamping: Int(($0 * 1000).rounded())) },
                UInt64(clamping: Int((s.distance * 100).rounded())),
            ])
            previous = s
        }
        w.write(local: 1, [end, 0, 4])

        // lap
        w.define(local: 3, global: 19, fields: [
            (253, .uint32), (2, .uint32), (7, .uint32), (8, .uint32), (9, .uint32),
            (19, .uint16), (20, .uint16), (15, .uint8), (16, .uint8), (17, .uint8), (18, .uint8),
            (0, .enum8), (1, .enum8), (25, .enum8), (254, .uint16),
        ])
        for (i, lap) in activity.laps.enumerated() {
            let m = ActivityMetrics(samples: activity.samples[lap.sampleRange.clamped(to: activity.samples.indices)],
                                    ftp: activity.ftp)
            w.write(local: 3, [
                fitTime(lap.endTime), fitTime(lap.startTime),
                ms(lap.endTime.timeIntervalSince(lap.startTime)), ms(lap.timerTime),
                cm(m.distance),
                UInt64(m.avgPower), UInt64(m.maxPower),
                m.avgHeartRate.map(UInt64.init), m.maxHeartRate.map(UInt64.init),
                m.avgCadence.map(UInt64.init), m.maxCadence.map(UInt64.init),
                9, 1, 2, UInt64(i),   // event lap, stop, cyclisme
            ])
        }

        // session
        w.define(local: 4, global: 18, fields: [
            (253, .uint32), (2, .uint32), (7, .uint32), (8, .uint32), (9, .uint32), (11, .uint16),
            (16, .uint8), (17, .uint8), (18, .uint8), (19, .uint8), (20, .uint16), (21, .uint16),
            (25, .uint16), (26, .uint16), (34, .uint16), (35, .uint16), (36, .uint16), (45, .uint16),
            (0, .enum8), (1, .enum8), (5, .enum8), (6, .enum8), (28, .enum8), (254, .uint16),
        ])
        w.write(local: 4, [
            end, start,
            ms(activity.endDate.timeIntervalSince(activity.startDate)), ms(timerTime),
            cm(all.distance), UInt64(all.kilojoules.rounded()),   // kcal ≈ kJ à vélo
            all.avgHeartRate.map(UInt64.init), all.maxHeartRate.map(UInt64.init),
            all.avgCadence.map(UInt64.init), all.maxCadence.map(UInt64.init),
            UInt64(all.avgPower), UInt64(all.maxPower),
            0, UInt64(activity.laps.count),
            UInt64(all.normalizedPower), UInt64((all.tss * 10).rounded()),
            UInt64((all.intensityFactor * 1000).rounded()), UInt64(max(activity.ftp, 0)),
            8, 1, 2, 6, 0, 0,   // event session, stop, cyclisme, home trainer, fin d'activité
        ])

        // activity
        w.define(local: 5, global: 34, fields: [
            (253, .uint32), (0, .uint32), (1, .uint16), (2, .enum8), (3, .enum8), (4, .enum8), (5, .uint32),
        ])
        let tz = UInt64(max(TimeZone.current.secondsFromGMT(for: activity.endDate), 0))
        w.write(local: 5, [end, ms(timerTime), 1, 0, 26, 1, end + tz])

        return w.finalize()
    }

    private static func ms(_ t: TimeInterval) -> UInt64 { UInt64(max(t, 0) * 1000) }
    private static func cm(_ m: Double) -> UInt64 { UInt64(max(m, 0) * 100) }
}

enum FITBaseType {
    case enum8, uint8, uint16, uint32, uint32z

    var code: UInt8 {
        switch self {
        case .enum8: 0x00
        case .uint8: 0x02
        case .uint16: 0x84
        case .uint32: 0x86
        case .uint32z: 0x8C
        }
    }

    var size: Int {
        switch self {
        case .enum8, .uint8: 1
        case .uint16: 2
        case .uint32, .uint32z: 4
        }
    }

    /// Valeur « invalide » du type, écrite quand une mesure est absente.
    var invalid: UInt64 {
        switch self {
        case .enum8, .uint8: 0xFF
        case .uint16: 0xFFFF
        case .uint32: 0xFFFF_FFFF
        case .uint32z: 0
        }
    }

    var max: UInt64 { invalid == 0 ? 0xFFFF_FFFF : invalid - 1 }
}

struct FITWriter {
    private var body = Data()
    private var definitions: [UInt8: [FITBaseType]] = [:]

    mutating func define(local: UInt8, global: UInt16, fields: [(UInt8, FITBaseType)]) {
        definitions[local] = fields.map(\.1)
        body.append(0x40 | local)           // en-tête de message de définition
        body.append(0)                      // réservé
        body.append(0)                      // little-endian
        append(UInt64(global), size: 2)
        body.append(UInt8(fields.count))
        for (num, type) in fields {
            body.append(contentsOf: [num, UInt8(type.size), type.code])
        }
    }

    mutating func write(local: UInt8, _ values: [UInt64?]) {
        guard let types = definitions[local] else {
            preconditionFailure("Message FIT local \(local) non défini")
        }
        precondition(types.count == values.count, "Nombre de champs FIT incohérent")
        body.append(local)
        for (type, value) in zip(types, values) {
            append(value.map { Swift.min($0, type.max) } ?? type.invalid, size: type.size)
        }
    }

    private mutating func append(_ value: UInt64, size: Int) {
        for i in 0..<size { body.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }

    /// Ajoute l'en-tête de 14 octets et les CRC.
    func finalize() -> Data {
        var header = Data([14, 0x20])
        let profile: UInt16 = 2132
        header.append(contentsOf: [UInt8(profile & 0xFF), UInt8(profile >> 8)])
        let size = UInt32(body.count)
        header.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) })
        header.append(contentsOf: Array(".FIT".utf8))
        let headerCRC = FITCRC.compute(header)
        header.append(contentsOf: [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)])

        var file = header + body
        let crc = FITCRC.compute(file)
        file.append(contentsOf: [UInt8(crc & 0xFF), UInt8(crc >> 8)])
        return file
    }
}

enum FITCRC {
    private static let table: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    static func compute(_ data: Data, initial: UInt16 = 0) -> UInt16 {
        var crc = initial
        for byte in data {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}
