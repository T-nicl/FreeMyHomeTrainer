import CoreBluetooth
import Foundation
import Observation

enum DeviceKind: String, Sendable {
    case trainer, heartRate
}

enum LinkState: Equatable, Sendable {
    case disconnected, connecting, connected

    var label: String {
        switch self {
        case .disconnected: "Déconnecté"
        case .connecting: "Connexion…"
        case .connected: "Connecté"
        }
    }
}

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var kind: DeviceKind
    var rssi: Int
}

/// Gère le Bluetooth : découverte, connexion et reconnexion du home trainer (FTMS)
/// et de la ceinture cardio, plus un trainer simulé pour développer sans vélo.
@MainActor
@Observable
final class DeviceManager: NSObject {
    // État Bluetooth
    private(set) var bluetoothReady = false
    private(set) var isScanning = false
    private(set) var discovered: [DiscoveredDevice] = []

    // Appareils
    private(set) var trainerName: String?
    private(set) var trainerState: LinkState = .disconnected
    private(set) var heartRateName: String?
    private(set) var heartRateState: LinkState = .disconnected
    /// Le trainer a accepté la prise de contrôle (mode ERG possible).
    private(set) var hasControl = false
    /// Incrémenté à chaque prise de contrôle réussie (connexion, reconnexion, reprise après une
    /// autre app) : le moteur de séance renvoie alors sa consigne.
    private(set) var controlGeneration = 0
    private(set) var powerRange: ClosedRange<Int>?
    private(set) var isSimulating = false

    // Mesures en direct
    private(set) var power: Int?
    private(set) var cadence: Double?
    private(set) var speedKmh: Double?
    private(set) var heartRate: Int?
    private var lastTrainerData: Date?
    private var lastHeartRateData: Date?
    private var trainerHeartRate: Int?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var trainer: CBPeripheral?
    @ObservationIgnored private var hrSensor: CBPeripheral?
    @ObservationIgnored private var candidates: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var controlPoint: CBCharacteristic?
    @ObservationIgnored private var commandQueue: [FTMSCommand] = []
    @ObservationIgnored private var inFlight: (command: FTMSCommand, sentAt: Date)?
    @ObservationIgnored private var simulator: SimulatedTrainer?
    @ObservationIgnored private var lastControlRequest: Date?
    @ObservationIgnored private var watchdog: Timer?

    private enum Keys {
        static let trainer = "savedTrainerID"
        static let heartRate = "savedHRID"
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        watchdog = RepeatingTimer.schedule(every: 1) { [weak self] in self?.checkStaleness() }
    }

    // MARK: - Mesures

    /// Fréquence cardiaque : ceinture si présente, sinon celle remontée par le trainer.
    var currentHeartRate: Int? { heartRate ?? trainerHeartRate }

    private func checkStaleness() {
        let now = Date()
        // Plus de données depuis 3 s : on considère les valeurs comme inconnues.
        if let t = lastTrainerData, now.timeIntervalSince(t) > 3 {
            power = nil; cadence = nil; speedKmh = nil; trainerHeartRate = nil
        }
        if let t = lastHeartRateData, now.timeIntervalSince(t) > 5 { heartRate = nil }
        // Commande sans réponse depuis 2 s : on passe à la suivante.
        if let f = inFlight, now.timeIntervalSince(f.sentAt) > 2 {
            inFlight = nil
            sendNextCommand()
        }
    }

    private func applyTrainerData(_ d: IndoorBikeData) {
        lastTrainerData = Date()
        if let p = d.power { power = max(p, 0) }
        if let c = d.cadence { cadence = c }
        if let s = d.speedKmh { speedKmh = s }
        if let hr = d.heartRate, hr > 0 { trainerHeartRate = hr }
    }

    // MARK: - Pilotage

    /// Demande au trainer de tenir une puissance (mode ERG).
    func setTargetPower(_ watts: Int) {
        var w = max(watts, 0)
        if let range = powerRange { w = min(max(w, range.lowerBound), range.upperBound) }
        if let simulator {
            simulator.targetPower = w
            return
        }
        // Une seule consigne en attente : la plus récente remplace les précédentes.
        commandQueue.removeAll { if case .setTargetPower = $0 { true } else { false } }
        enqueue(.setTargetPower(w))
    }

    /// Mode libre : simulation de pente (résistance gérée par le trainer).
    func setGrade(_ percent: Double) {
        if let simulator {
            simulator.targetPower = nil
            return
        }
        commandQueue.removeAll { if case .setSimulation = $0 { true } else { false } }
        enqueue(.setSimulation(gradePercent: percent))
    }

    private func enqueue(_ command: FTMSCommand) {
        commandQueue.append(command)
        sendNextCommand()
    }

    private func sendNextCommand() {
        guard inFlight == nil, let trainer, let controlPoint, !commandQueue.isEmpty else { return }
        let command = commandQueue.removeFirst()
        inFlight = (command, Date())
        trainer.writeValue(command.data, for: controlPoint, type: .withResponse)
    }

    private func handleControlPointResponse(_ data: Data) {
        guard let response = FTMSParser.parseControlPointResponse(data) else { return }
        if response.opcode == FTMSCommand.requestControl.opcode {
            hasControl = response.success
            if response.success {
                controlGeneration += 1
                // « Start » avant toute consigne déjà en file : certains trainers refusent une
                // consigne reçue avant le démarrage.
                commandQueue.insert(.start, at: 0)
            }
        } else if response.opcode == FTMSCommand.setTargetPower(0).opcode,
                  response.result == FTMSParser.controlNotPermitted {
            // Consigne refusée faute de contrôle : on le redemande. (Un autre refus — valeur hors
            // plage, non supporté… — ne se règle pas en reprenant le contrôle.)
            requestControlAgain()
        }
        if let f = inFlight, f.command.opcode == response.opcode { inFlight = nil }
        sendNextCommand()
    }

    // MARK: - Découverte et connexion

    func startScan() {
        guard bluetoothReady, !isScanning else { return }
        discovered.removeAll()
        isScanning = true
        // Sans filtre : certains trainers n'annoncent FTMS que dans la réponse au scan.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredDevice) {
        guard let peripheral = candidates[device.id] else { return }
        stopSimulation()
        stopScan()                       // appareil choisi : inutile de garder la radio en recherche
        connect(peripheral, as: device.kind)
        UserDefaults.standard.set(device.id.uuidString, forKey: device.kind == .trainer ? Keys.trainer : Keys.heartRate)
    }

    func disconnect(_ kind: DeviceKind, forget: Bool = false) {
        let peripheral = kind == .trainer ? trainer : hrSensor
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        if kind == .trainer {
            trainer = nil; trainerName = nil; trainerState = .disconnected
            resetTrainerLink()
        } else {
            hrSensor = nil; heartRateName = nil; heartRateState = .disconnected; heartRate = nil
        }
        if forget {
            UserDefaults.standard.removeObject(forKey: kind == .trainer ? Keys.trainer : Keys.heartRate)
        }
    }

    private func connect(_ peripheral: CBPeripheral, as kind: DeviceKind) {
        peripheral.delegate = self
        switch kind {
        case .trainer:
            if let old = trainer, old.identifier != peripheral.identifier { central.cancelPeripheralConnection(old) }
            trainer = peripheral
            trainerName = peripheral.name ?? "Home trainer"
            trainerState = .connecting
        case .heartRate:
            if let old = hrSensor, old.identifier != peripheral.identifier { central.cancelPeripheralConnection(old) }
            hrSensor = peripheral
            heartRateName = peripheral.name ?? "Cardio"
            heartRateState = .connecting
        }
        central.connect(peripheral)
    }

    /// Redemande le contrôle, au plus une fois toutes les 10 s : si une autre app (Zwift…) se
    /// dispute le trainer, on évite un ping-pong de commandes.
    private func requestControlAgain(now: Date = Date()) {
        guard controlPoint != nil, !commandQueue.contains(.requestControl) else { return }
        if let last = lastControlRequest, now.timeIntervalSince(last) < 10 { return }
        lastControlRequest = now
        commandQueue.insert(.requestControl, at: 0)
        sendNextCommand()
    }

    private func resetTrainerLink() {
        controlPoint = nil; hasControl = false; powerRange = nil
        commandQueue.removeAll(); inFlight = nil
        power = nil; cadence = nil; speedKmh = nil; trainerHeartRate = nil
    }

    /// Reconnexion automatique aux appareils mémorisés.
    private func reconnectSavedDevices() {
        for (key, kind) in [(Keys.trainer, DeviceKind.trainer), (Keys.heartRate, .heartRate)] {
            guard let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw),
                  let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else { continue }
            connect(peripheral, as: kind)
        }
    }

    // MARK: - Simulation

    func startSimulation() {
        if let trainer { central.cancelPeripheralConnection(trainer) }
        trainer = nil
        resetTrainerLink()
        let sim = SimulatedTrainer { [weak self] data in self?.applyTrainerData(data) }
        simulator = sim
        isSimulating = true
        trainerName = "Trainer simulé"
        trainerState = .connected
        hasControl = true
        controlGeneration += 1
        powerRange = 0...2000
        sim.start()
    }

    func stopSimulation() {
        guard let simulator else { return }
        simulator.stop()
        self.simulator = nil
        isSimulating = false
        trainerName = nil
        trainerState = .disconnected
        resetTrainerLink()
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothReady = central.state == .poweredOn
        if bluetoothReady {
            reconnectSavedDevices()
        } else {
            // Bluetooth du Mac coupé : les liens sont perdus ; ne pas afficher « connecté ».
            isScanning = false
            if trainer != nil {
                resetTrainerLink()
                trainerState = .connecting
            }
            if hrSensor != nil {
                heartRate = nil
                heartRateState = .connecting
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let kind: DeviceKind
        if services.contains(CBUUID(string: GATT.fitnessMachineService)) || name?.uppercased().contains("KICKR") == true {
            kind = .trainer
        } else if services.contains(CBUUID(string: GATT.heartRateService)) {
            kind = .heartRate
        } else {
            return
        }
        candidates[peripheral.identifier] = peripheral
        let device = DiscoveredDevice(id: peripheral.identifier, name: name ?? "Appareil inconnu",
                                      kind: kind, rssi: RSSI.intValue)
        if let i = discovered.firstIndex(where: { $0.id == device.id }) {
            discovered[i] = device
        } else {
            discovered.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral == trainer {
            trainerState = .connected
            peripheral.discoverServices([CBUUID(string: GATT.fitnessMachineService)])
        } else if peripheral == hrSensor {
            heartRateState = .connected
            peripheral.discoverServices([CBUUID(string: GATT.heartRateService)])
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleDisconnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnection(peripheral)
    }

    private func handleDisconnection(_ peripheral: CBPeripheral) {
        // Coupure inattendue : on relance la connexion (elle aboutira dès que l'appareil revient).
        if peripheral == trainer {
            resetTrainerLink()
            trainerState = .connecting
            central.connect(peripheral)
        } else if peripheral == hrSensor {
            heartRate = nil
            heartRateState = .connecting
            central.connect(peripheral)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case CBUUID(string: GATT.indoorBikeData), CBUUID(string: GATT.machineStatus),
                 CBUUID(string: GATT.heartRateMeasurement):
                peripheral.setNotifyValue(true, for: c)
            case CBUUID(string: GATT.controlPoint):
                controlPoint = c
                peripheral.setNotifyValue(true, for: c)
            case CBUUID(string: GATT.supportedPowerRange):
                peripheral.readValue(for: c)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Les indications du Control Point sont actives : on peut demander le contrôle.
        if characteristic.uuid == CBUUID(string: GATT.controlPoint), error == nil, peripheral == trainer {
            commandQueue.removeAll { $0 == .requestControl }
            commandQueue.insert(.requestControl, at: 0)
            sendNextCommand()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case CBUUID(string: GATT.indoorBikeData):
            if let d = FTMSParser.parseIndoorBikeData(data) { applyTrainerData(d) }
        case CBUUID(string: GATT.controlPoint):
            handleControlPointResponse(data)
        case CBUUID(string: GATT.supportedPowerRange):
            powerRange = FTMSParser.parsePowerRange(data)
        case CBUUID(string: GATT.heartRateMeasurement):
            if let hr = FTMSParser.parseHeartRate(data), hr > 0 {      // 0 = contact perdu
                heartRate = hr
                lastHeartRateData = Date()
            }
        case CBUUID(string: GATT.machineStatus):
            // 0xFF : le contrôle a été pris par une autre app (ex. Zwift).
            // On redemande le contrôle : la séance en cours renverra sa consigne une fois repris.
            if data.first == 0xFF {
                hasControl = false
                requestControlAgain()
            }
        default:
            break
        }
    }
}
