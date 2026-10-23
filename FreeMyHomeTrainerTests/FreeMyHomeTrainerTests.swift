import Foundation
import Testing
@testable import FreeMyHomeTrainer

// MARK: - Modèle de séance

struct WorkoutModelTests {
    @Test func jsonRoundTripKeepsStructure() throws {
        let workout = Workout(name: "Test", blocks: [
            .ramp(600, from: .ftpPercent(50), to: .ftpPercent(75)),
            .repeats(3, [.steady(600, .watts(200)), .steady(300, .ftpPercent(55))]),
        ])
        let decoded = try Workout.from(json: workout.jsonData())
        #expect(decoded.name == "Test")
        #expect(decoded.totalDuration == workout.totalDuration)
        #expect(decoded.blocks[1].kind == .repeats)
        #expect(decoded.blocks[1].blocks[0].target == .watts(200))
    }

    @Test func decodesHandwrittenJSON() throws {
        // Format qu'un LLM devra produire.
        let json = """
        {"name":"Tempo 3x10'","blocks":[
          {"type":"steady","duration":600,"target":{"ftp":60}},
          {"type":"repeat","count":3,"blocks":[
            {"type":"steady","duration":600,"target":{"ftp":85}},
            {"type":"steady","duration":300,"target":{"watts":120}}]}]}
        """
        let w = try Workout.from(json: Data(json.utf8))
        #expect(w.totalDuration == 600 + 3 * 900)
        #expect(w.notes == "")
    }

    @Test func timelineFlattensRepeatsAndResolvesFTP() {
        let w = Workout(name: "x", blocks: [
            .steady(60, .ftpPercent(50)),
            .repeats(2, [.steady(30, .watts(300)), .steady(30, .ftpPercent(60))]),
        ])
        let tl = WorkoutTimeline(workout: w, ftp: 200)
        #expect(tl.segments.count == 5)
        #expect(tl.duration == 180)
        #expect(tl.segments[0].startWatts == 100)
        #expect(tl.segments[3].start == 120)
        #expect(tl.segments[3].repetition?.index == 2)
        #expect(tl.targetWatts(at: 65) == 300)
        #expect(tl.targetWatts(at: 179) == 120)
        #expect(tl.targetWatts(at: 180) == nil)
    }

    @Test func rampInterpolatesAndTSSMatchesFormula() {
        let w = Workout(name: "x", blocks: [.ramp(100, from: .watts(100), to: .watts(200))])
        let tl = WorkoutTimeline(workout: w, ftp: 200)
        #expect(tl.targetWatts(at: 50) == 150)
        // Une heure à FTP = 100 TSS.
        let ftpHour = WorkoutTimeline(workout: Workout(name: "y", blocks: [.steady(3600, .ftpPercent(100))]), ftp: 250)
        #expect(abs(ftpHour.trainingStressScore - 100) < 0.01)
    }

    @Test func intensityRatingOfSampleWorkouts() {
        func rating(_ name: String) -> Double {
            WorkoutTimeline(workout: Workout.samples.first { $0.name.hasPrefix(name) }!, ftp: 250).intensityRating
        }
        #expect(rating("Endurance") == 1.5)
        #expect(rating("Sweet Spot") == 2.5)
        #expect(rating("VO2") == 4)
    }

    @Test func intensityRatingCalibration() {
        // Exemples donnés par l'utilisateur, FTP 245 W.
        func steady(_ watts: Int, minutes: Double) -> Double {
            let w = Workout(name: "x", blocks: [.steady(minutes * 60, .watts(watts))])
            return WorkoutTimeline(workout: w, ftp: 245).intensityRating
        }
        #expect(steady(170, minutes: 45) == 1.5)
        #expect(steady(250, minutes: 45) == 5)
        #expect(steady(120, minutes: 45) == 1)
        // À 100 % de la FTP, plus c'est long, plus c'est dur.
        #expect(steady(245, minutes: 10) == 3.5)
        #expect(steady(245, minutes: 26) == 4)
        #expect(steady(245, minutes: 45) == 4.5)
        #expect(steady(245, minutes: 60) == 5)
        // La durée pèse au-delà d'une heure, et un peu en moins sous 20 minutes.
        #expect(steady(170, minutes: 180) > steady(170, minutes: 60))
        #expect(steady(200, minutes: 15) < steady(200, minutes: 45))
    }

    @Test func sanityWarnings() {
        let ftp = 245
        func warnings(_ blocks: [WorkoutBlock]) -> [String] {
            WorkoutSanity.warnings(for: Workout(name: "x", blocks: blocks), ftp: ftp)
        }
        // L'exemple de l'utilisateur : 3 × 10' à 400 % FTP.
        let absurd = warnings([.repeats(3, [.steady(600, .ftpPercent(400)), .steady(300, .ftpPercent(50))])])
        #expect(absurd.count == 1)
        #expect(absurd.first?.contains("400 % FTP") == true)
        #expect(!warnings([.steady(1200, .watts(2500))]).isEmpty)                 // > 2 000 W
        #expect(!warnings([.steady(7200, .ftpPercent(100))]).isEmpty)             // 2 h au seuil

        // Séances dures mais réalistes : aucun avertissement.
        #expect(warnings([.repeats(5, [.steady(180, .ftpPercent(118)), .steady(180, .ftpPercent(50))])]).isEmpty)
        #expect(warnings([.repeats(20, [.steady(30, .ftpPercent(150)), .steady(30, .ftpPercent(50))])]).isEmpty)
        #expect(warnings([.steady(3600, .ftpPercent(100))]).isEmpty)
        #expect(warnings([.steady(10, .ftpPercent(400))]).isEmpty)                // sprint de 10 s
        for sample in Workout.samples {
            #expect(WorkoutSanity.warnings(for: sample, ftp: ftp).isEmpty, "\(sample.name)")
        }
    }

    @Test func powerZones() {
        #expect(PowerZone(watts: 100, ftp: 200) == .z1)
        #expect(PowerZone(watts: 180, ftp: 200) == .z3)
        #expect(PowerZone(watts: 200, ftp: 200) == .z4)
        #expect(PowerZone(watts: 300, ftp: 200) == .z6)
    }

    @Test func blockTreeEditing() {
        var blocks: [WorkoutBlock] = [.steady(60, .watts(100)), .repeats(2, [.steady(30, .watts(200))])]
        let childID = blocks[1].blocks[0].id
        #expect(blocks.parentID(of: childID) == blocks[1].id)
        _ = blocks.duplicate(childID)
        #expect(blocks[1].blocks.count == 2)
        #expect(blocks[1].blocks[0].id != blocks[1].blocks[1].id)
        blocks.move(blocks[1].id, by: -1)
        #expect(blocks[0].kind == .repeats)
        blocks.remove(childID)
        #expect(blocks[0].blocks.count == 1)
    }

    @Test func dragAndDropMoves() {
        let a = WorkoutBlock.steady(60, .watts(100))
        let b = WorkoutBlock.steady(60, .watts(200))
        let child = WorkoutBlock.steady(30, .watts(300))
        let rep = WorkoutBlock.repeats(2, [child])
        var blocks = [a, b, rep]

        // Échanger : déposer A après B.
        do { let moved = blocks.moveBlock(a.id, relativeTo: b.id, after: true); #expect(moved) }
        #expect(blocks.map(\.id) == [b.id, a.id, rep.id])

        // Sortir un bloc d'une répétition, puis l'y remettre.
        do { let moved = blocks.moveBlock(child.id, relativeTo: b.id, after: false); #expect(moved) }
        #expect(blocks.map(\.id) == [child.id, b.id, a.id, rep.id])
        do { let moved = blocks.moveBlock(child.id, intoRepeat: rep.id); #expect(moved) }
        #expect(blocks[2].blocks.map(\.id) == [child.id])

        // Interdits : répétition dans une répétition, bloc sur lui-même.
        do { let moved = blocks.moveBlock(rep.id, relativeTo: child.id, after: true); #expect(!moved) }
        do { let moved = blocks.moveBlock(rep.id, intoRepeat: rep.id); #expect(!moved) }
        do { let moved = blocks.moveBlock(a.id, relativeTo: a.id, after: true); #expect(!moved) }
        #expect(blocks.count == 3)

        blocks.moveBlockToEnd(b.id)
        #expect(blocks.last?.id == b.id)
    }

    @Test func nestedRepeats() throws {
        // 2 × (8 × (1' à 300 W, 1' à 150 W)) avec 5' de récupération entre les deux séries.
        let inner = WorkoutBlock.repeats(8, [.steady(60, .watts(300)), .steady(60, .watts(150))])
        let w = Workout(name: "2x8x1'", blocks: [.repeats(2, [inner, .steady(300, .watts(120))])])
        let tl = WorkoutTimeline(workout: w, ftp: 250)
        #expect(tl.segments.count == 2 * (16 + 1))
        #expect(tl.duration == 2 * (16 * 60 + 300))
        #expect(tl.targetWatts(at: 60 * 16 + 300 + 30) == 300)     // 1re minute de la 2e série

        let decoded = try Workout.from(json: w.jsonData())
        #expect(decoded.blocks[0].blocks[0].kind == .repeats)
        #expect(decoded.blocks[0].blocks[0].count == 8)
        #expect(w.blocks.nestingDepth == 2)

        // Une répétition peut maintenant entrer dans une autre.
        let a = WorkoutBlock.repeats(3, [.steady(60, .watts(200))])
        let b = WorkoutBlock.repeats(2, [.steady(30, .watts(300))])
        var blocks = [a, b]
        do { let moved = blocks.moveBlock(b.id, intoRepeat: a.id); #expect(moved) }
        #expect(blocks.count == 1)
        #expect(blocks[0].blocks.last?.id == b.id)
        // …mais jamais dans ses propres enfants.
        do { let moved = blocks.moveBlock(a.id, intoRepeat: b.id); #expect(!moved) }
    }

    @Test func durationParsing() throws {
        let p = DurationParseStrategy()
        #expect(try p.parse("10") == 600)
        #expect(try p.parse("1:30") == 90)
        #expect(try p.parse("10'30") == 630)
        #expect(try p.parse("1:00:00") == 3600)
        #expect(throws: (any Error).self) { try p.parse("abc") }
        #expect(throws: (any Error).self) { try p.parse("0") }
        #expect(DurationFormat().format(630) == "10:30")
    }
}

// MARK: - Glisser-déposer de l'éditeur

struct BlockDropResolverTests {
    // Frise : [A] [Répétition (C)] [B], positions fictives dans le repère de l'éditeur.
    let a = WorkoutBlock.steady(60, .watts(100))
    let c = WorkoutBlock.steady(60, .watts(200))
    let b = WorkoutBlock.steady(60, .watts(150))
    let rep: WorkoutBlock

    init() { rep = .repeats(2, [c]) }

    func resolve(_ x: CGFloat, _ y: CGFloat, dragging payload: BlockDragPayload) -> BlockDropTarget? {
        let items: [WorkoutBlock.ID: BlockFrames.Item] = [
            a.id: .init(rect: CGRect(x: 0, y: 40, width: 100, height: 190), isRepeat: false, depth: 0),
            rep.id: .init(rect: CGRect(x: 104, y: 0, width: 200, height: 230), isRepeat: true, depth: 0),
            c.id: .init(rect: CGRect(x: 116, y: 40, width: 80, height: 190), isRepeat: false, depth: 1),
            b.id: .init(rect: CGRect(x: 308, y: 40, width: 100, height: 190), isRepeat: false, depth: 0),
        ]
        return BlockDropResolver.target(at: CGPoint(x: x, y: y), payload: payload, blocks: [a, rep, b],
                                        items: items, timeline: CGRect(x: 0, y: 0, width: 500, height: 260))
    }

    @Test func halvesOfABlock() {
        #expect(resolve(30, 100, dragging: .existing(b.id)) == .relative(a.id, after: false))
        #expect(resolve(80, 100, dragging: .existing(b.id)) == .relative(a.id, after: true))
        #expect(resolve(150, 100, dragging: .existing(b.id)) == .relative(c.id, after: false))
    }

    @Test func repeatEdgesAndInside() {
        #expect(resolve(110, 100, dragging: .existing(b.id)) == .relative(rep.id, after: false))
        #expect(resolve(300, 100, dragging: .existing(b.id)) == .relative(rep.id, after: true))
        #expect(resolve(250, 100, dragging: .existing(b.id)) == .intoRepeat(rep.id))
        #expect(resolve(250, 100, dragging: .new(.steady)) == .intoRepeat(rep.id))
    }

    @Test func gapsAndOutside() {
        // Hors de toute zone (au-dessus des barres) : d'après la position horizontale.
        #expect(resolve(350, 20, dragging: .existing(a.id)) == .relative(b.id, after: false))
        #expect(resolve(450, 20, dragging: .existing(a.id)) == .relative(b.id, after: true))
        #expect(resolve(600, 100, dragging: .existing(a.id)) == nil)          // hors de la frise
    }

    @Test func invalidTargets() {
        #expect(resolve(30, 100, dragging: .existing(a.id)) == nil)            // sur lui-même
        #expect(resolve(150, 100, dragging: .existing(rep.id)) == nil)         // dans ses sous-blocs
        #expect(BlockDropResolver.target(at: CGPoint(x: 10, y: 10), payload: .new(.steady), blocks: [],
                                         items: [:], timeline: CGRect(x: 0, y: 0, width: 100, height: 100)) == .end)
    }
}

// MARK: - Bluetooth FTMS

struct FTMSParserTests {
    @Test func parsesSpeedCadencePower() {
        // Flags 0x0044 : vitesse (bit 0 à 0), cadence (bit 2), puissance (bit 6).
        let data = Data([0x44, 0x00, 0xB8, 0x0B, 0xB4, 0x00, 0xC8, 0x00])
        let d = FTMSParser.parseIndoorBikeData(data)
        #expect(d?.speedKmh == 30)
        #expect(d?.cadence == 90)
        #expect(d?.power == 200)
        #expect(d?.heartRate == nil)
    }

    @Test func skipsOptionalFieldsAndReadsHeartRate() {
        // Flags : more data (bit 0), distance (bit 4), puissance (bit 6), énergie (bit 8), FC (bit 9).
        let flags: UInt16 = 1 << 0 | 1 << 4 | 1 << 6 | 1 << 8 | 1 << 9
        var bytes = [UInt8(flags & 0xFF), UInt8(flags >> 8)]
        bytes += [0x10, 0x27, 0x00]             // distance 10000 m
        bytes += [0x2C, 0x01]                   // 300 W
        bytes += [0x01, 0x00, 0x02, 0x00, 0x03] // énergie (ignorée)
        bytes += [142]                          // FC
        let d = FTMSParser.parseIndoorBikeData(Data(bytes))
        #expect(d?.speedKmh == nil)
        #expect(d?.totalDistance == 10000)
        #expect(d?.power == 300)
        #expect(d?.heartRate == 142)
    }

    @Test func truncatedFrameDoesNotCrash() {
        #expect(FTMSParser.parseIndoorBikeData(Data([0x44, 0x00, 0xB8]))?.power == nil)
        #expect(FTMSParser.parseIndoorBikeData(Data()) == nil)
    }

    @Test func heartRateFormats() {
        #expect(FTMSParser.parseHeartRate(Data([0x00, 150])) == 150)
        #expect(FTMSParser.parseHeartRate(Data([0x01, 0x2C, 0x01])) == 300)
    }

    @Test func commandsEncoding() {
        #expect(FTMSCommand.setTargetPower(250).data == Data([0x05, 0xFA, 0x00]))
        #expect(FTMSCommand.requestControl.data == Data([0x00]))
        #expect(FTMSCommand.setSimulation(gradePercent: -2.5).data == Data([0x11, 0, 0, 0x06, 0xFF, 40, 51]))
        let response = FTMSParser.parseControlPointResponse(Data([0x80, 0x05, 0x01]))
        #expect(response?.opcode == 0x05)
        #expect(response?.success == true)
        #expect(FTMSParser.parsePowerRange(Data([0x00, 0x00, 0xD0, 0x07, 0x01, 0x00])) == 0...2000)
    }
}

// MARK: - Moteur de séance

@MainActor
final class MockSource: RideDataSource {
    var power: Int? = 150
    var cadence: Double? = 90
    var currentHeartRate: Int? = 140
    var targets: [Int] = []
    var grades: [Double] = []

    func setTargetPower(_ watts: Int) { targets.append(watts) }
    func setGrade(_ percent: Double) { grades.append(percent) }
}

@MainActor
struct WorkoutEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func makeEngine(_ source: MockSource) -> WorkoutEngine {
        let w = Workout(name: "x", blocks: [.steady(60, .watts(100)), .steady(30, .watts(200))])
        return WorkoutEngine(workout: w, ftp: 200, source: source)
    }

    @Test func sendsTargetsAtSegmentChangesAndRecordsLaps() {
        let source = MockSource()
        let engine = makeEngine(source)
        engine.start(at: t0, autoTick: false)
        for i in 1...100 { engine.tick(now: t0.addingTimeInterval(TimeInterval(i))) }

        #expect(source.targets == [100, 200])
        #expect(source.grades == [0])               // trainer libéré à la fin de la séance
        #expect(engine.elapsed == 100)
        #expect(engine.samples.count == 100)
        #expect(engine.isWorkoutComplete)
        #expect(engine.laps.count == 2)
        #expect(engine.laps[0].timerTime == 60)
        #expect(engine.distance > 700 && engine.distance < 1000)   // vélo virtuel à 150 W, départ arrêté
        #expect(engine.speedKmh > 28 && engine.speedKmh < 34)

        engine.finish(now: t0.addingTimeInterval(101))
        #expect(engine.state == .finished)
        #expect(engine.laps.count == 3)             // + la roue libre après la séance
    }

    @Test func autoPausesWhenPedalingStops() {
        let source = MockSource()
        let engine = makeEngine(source)
        engine.start(at: t0, autoTick: false)
        for i in 1...10 { engine.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        source.power = 0
        source.cadence = 0
        for i in 11...20 { engine.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        #expect(engine.state == .autoPaused)
        let frozen = engine.elapsed
        #expect(frozen < 15)
        source.cadence = 85
        engine.tick(now: t0.addingTimeInterval(21))
        #expect(engine.state == .running)
        #expect(engine.elapsed == frozen + 1)
    }

    @Test func manualPauseFreezesTime() {
        let source = MockSource()
        let engine = makeEngine(source)
        engine.start(at: t0, autoTick: false)
        engine.tick(now: t0.addingTimeInterval(5))   // dt plafonné à 2 s
        #expect(engine.elapsed == 2)
        engine.togglePause()
        engine.tick(now: t0.addingTimeInterval(6))
        #expect(engine.elapsed == 2)
        engine.togglePause()
        engine.tick(now: t0.addingTimeInterval(7))
        #expect(engine.elapsed == 3)
    }

    @Test func intensityAndSkip() {
        let source = MockSource()
        let engine = makeEngine(source)
        engine.start(at: t0, autoTick: false)
        engine.adjustIntensity(by: 0.05, now: t0)
        #expect(engine.targetWatts == 105)
        #expect(source.targets.last == 105)
        for i in 1...5 { engine.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        engine.skipSegment(now: t0.addingTimeInterval(6))
        #expect(engine.position == 60)
        #expect(engine.elapsed == 5)                // le temps sauté n'est pas compté comme roulé
        #expect(engine.targetWatts == 210)
        #expect(engine.laps.count == 1)
    }
}

struct VirtualBikeTests {
    @Test func roadBikeSpeedsOnTheFlat() {
        let bike = VirtualBike(riderMass: 70)
        let kmh = { (w: Double) in bike.steadySpeed(power: w) * 3.6 }
        #expect(kmh(100) > 26 && kmh(100) < 29)
        #expect(kmh(200) > 33.5 && kmh(200) < 36.5)
        #expect(kmh(300) > 38.5 && kmh(300) < 42)
        #expect(kmh(0) < 0.1)
    }

    @Test func accelerationReachesSteadySpeed() {
        var bike = VirtualBike(riderMass: 70)
        for _ in 0..<120 { bike.step(power: 200, dt: 1) }
        #expect(abs(bike.speed - bike.steadySpeed(power: 200)) < 0.1)
        bike.step(power: 0, dt: 10)                 // roue libre : ralentit sans s'arrêter net
        #expect(bike.speed < bike.steadySpeed(power: 200) && bike.speed > 5)
    }
}

// MARK: - Statistiques et FIT

struct MetricsTests {
    @Test func normalizedPowerOfConstantEffortEqualsAverage() {
        let samples = (0..<600).map { i in
            Sample(timestamp: Date(timeIntervalSince1970: TimeInterval(i)), elapsed: TimeInterval(i),
                   power: 200, cadence: 90, heartRate: 140, speed: 10, distance: Double(i + 1) * 10, target: 200)
        }
        let m = ActivityMetrics(samples: samples, ftp: 200)
        #expect(m.avgPower == 200)
        #expect(m.normalizedPower == 200)
        #expect(abs(m.tss - 600.0 / 3600 * 100) < 0.01)
        #expect(m.distance == 6000)
        #expect(m.kilojoules == 120)
    }
}

/// Décodeur FIT minimal (en-têtes normaux uniquement), pour vérifier l'encodeur.
struct FITTestDecoder {
    struct Message { let global: UInt16; var fields: [UInt8: UInt64] }

    static func decode(_ data: Data) throws -> [Message] {
        let bytes = [UInt8](data)
        let headerSize = Int(bytes[0])
        let dataSize = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        var defs: [UInt8: (UInt16, [(UInt8, Int)])] = [:]
        var out: [Message] = []
        var i = headerSize
        while i < headerSize + dataSize {
            let header = bytes[i]; i += 1
            let local = header & 0x0F
            if header & 0x40 != 0 {
                let global = UInt16(bytes[i + 2]) | UInt16(bytes[i + 3]) << 8
                let n = Int(bytes[i + 4]); i += 5
                var fields: [(UInt8, Int)] = []
                for _ in 0..<n { fields.append((bytes[i], Int(bytes[i + 1]))); i += 3 }
                defs[local] = (global, fields)
            } else {
                guard let (global, fields) = defs[local] else { throw CocoaError(.fileReadCorruptFile) }
                var msg = Message(global: global, fields: [:])
                for (num, size) in fields {
                    var v: UInt64 = 0
                    for k in 0..<size { v |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
                    msg.fields[num] = v
                    i += size
                }
                out.append(msg)
            }
        }
        return out
    }
}

struct FITEncoderTests {
    @Test func crcAndContentAreConsistent() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [Sample] = []
        for i in 0..<120 {
            // Pause de 30 s entre la 60e et la 61e seconde.
            let t = start.addingTimeInterval(TimeInterval(i < 60 ? i + 1 : i + 31))
            samples.append(Sample(timestamp: t, elapsed: TimeInterval(i + 1), power: i < 60 ? 150 : 250,
                                  cadence: 90, heartRate: i % 10 == 0 ? nil : 140, speed: 10,
                                  distance: Double(i + 1) * 10, target: 150))
        }
        let laps = [
            Lap(startTime: start, endTime: start.addingTimeInterval(60), timerTime: 60, sampleRange: 0..<60),
            Lap(startTime: start.addingTimeInterval(90), endTime: start.addingTimeInterval(151), timerTime: 60,
                sampleRange: 60..<120),
        ]
        let fit = FITEncoder.encode(FITActivity(startDate: start, endDate: start.addingTimeInterval(151),
                                                ftp: 250, samples: samples, laps: laps))

        // En-tête et CRC global : le CRC de tout le fichier (CRC inclus) vaut 0.
        #expect(fit.count > 14)
        #expect(String(decoding: fit[8..<12], as: UTF8.self) == ".FIT")
        #expect(FITCRC.compute(fit[0..<12]) == UInt16(fit[12]) | UInt16(fit[13]) << 8)
        #expect(FITCRC.compute(fit) == 0)

        let messages = try FITTestDecoder.decode(fit)
        let records = messages.filter { $0.global == 20 }
        #expect(records.count == 120)
        #expect(records[0].fields[253] == UInt64(1_700_000_001 - 631_065_600))
        #expect(records[0].fields[7] == 150)
        #expect(records[0].fields[3] == 0xFF)                   // FC absente = invalide
        #expect(records[0].fields[6] == 10_000)                 // 10 m/s en mm/s

        let events = messages.filter { $0.global == 21 }
        #expect(events.count == 4)                              // start, stop+start (pause), stop

        let lapMessages = messages.filter { $0.global == 19 }
        #expect(lapMessages.count == 2)
        #expect(lapMessages[1].fields[19] == 250)               // puissance moyenne du 2e tour

        let session = try #require(messages.first { $0.global == 18 })
        #expect(session.fields[20] == 200)                      // puissance moyenne
        #expect(session.fields[8] == 120_000)                   // temps de chrono en ms
        #expect(session.fields[6] == 6)                         // sous-sport : home trainer
        #expect(session.fields[45] == 250)                      // FTP

        #expect(messages.contains { $0.global == 34 })          // activity
        #expect(messages.first?.global == 0)                    // file_id en premier

        // FIT_DUMP=1 : écrit le fichier pour le valider avec un outil externe (SDK FIT Garmin).
        if ProcessInfo.processInfo.environment["FIT_DUMP"] != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample.fit")
            try fit.write(to: url)
            print("FIT_DUMP_PATH=\(url.path)")
        }
    }
}

// MARK: - OAuth 1 (Garmin)

struct OAuth1Tests {
    @Test func signatureMatchesTwitterReferenceExample() {
        // Exemple de la documentation Twitter « Creating a signature ».
        let header = OAuth1.header(
            method: "POST", url: "https://api.twitter.com/1.1/statuses/update.json",
            params: ["status": "Hello Ladies + Gentlemen, a signed OAuth request!", "include_entities": "true"],
            consumerKey: "xvz1evFS4wEEPTGEFPHBog",
            consumerSecret: "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw",
            token: "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb",
            tokenSecret: "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE",
            nonce: "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg",
            timestamp: 1_318_622_958)
        #expect(header.contains("oauth_signature=\"hCtSmYh%2BiHYCEqBWrE7C7hYmtUk%3D\""))
    }

    @Test func garminTicketExtraction() {
        let url = "https://sso.garmin.com/sso/embed?ticket=ST-0123456-AbCdEf-cas"
        #expect(GarminClient.ticket(in: url) == "ST-0123456-AbCdEf-cas")
        let html = #"<script>var response_url = "https:\/\/sso.garmin.com\/sso\/embed?ticket=ST-987-xyz-cas";</script>"#
        #expect(GarminClient.ticket(in: html) == "ST-987-xyz-cas")
        #expect(GarminClient.ticket(in: "<title>GARMIN Authentication</title>") == nil)
    }

    @Test func formEncodingRoundTrip() {
        let decoded = FormEncoding.decode("oauth_token=abc%2Fdef&oauth_token_secret=x%3Dy&mfa_token=")
        #expect(decoded["oauth_token"] == "abc/def")
        #expect(decoded["oauth_token_secret"] == "x=y")
        #expect(decoded["mfa_token"] == "")
    }
}
