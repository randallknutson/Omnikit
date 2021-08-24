//
//  PeripheralManager.swift
//  xDripG5
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log

protocol MessageResult {
    
}

struct MessageSendFailure: MessageResult {
    
}

struct MessageSendSuccess: MessageResult {
    
}

class PeripheralManager: NSObject {

    private let log = OSLog(category: "PeripheralManager")

    ///
    /// This is mutable, because CBPeripheral instances can seemingly become invalid, and need to be periodically re-fetched from CBCentralManager
    var peripheral: CBPeripheral {
        didSet {
            guard oldValue !== peripheral else {
                return
            }

            log.error("Replacing peripheral reference %{public}@ -> %{public}@", oldValue, peripheral)

            oldValue.delegate = nil
            peripheral.delegate = self

            queue.sync {
                self.needsConfiguration = true
            }
        }
    }
    
    let serviceUUID = CBUUID(string: "1A7E4024-E3ED-4464-8B7E-751E03D0DC5F")
    let cmdCharacteristicUUID = CBUUID(string: "1A7E2441-E3ED-4464-8B7E-751E03D0DC5F")
    let dataCharacteristicUUID = CBUUID(string: "1A7E2442-E3ED-4464-8B7E-751E03D0DC5F")
    var cmdCharacteristic: CBCharacteristic?
    var dataCharacteristic: CBCharacteristic?
    
    /// The dispatch queue used to serialize operations on the peripheral
    let queue: DispatchQueue

    /// The condition used to signal command completion
    private let commandLock = NSCondition()

    /// The required conditions for the operation to complete
    private var commandConditions = [CommandCondition]()

    /// Any error surfaced during the active operation
    private var commandError: Error?

    private(set) weak var central: CBCentralManager?
    
    // Confined to `queue`
    private var needsConfiguration = true
    
    weak var delegate: PeripheralManagerDelegate? {
        didSet {
            queue.sync {
                needsConfiguration = true
            }
        }
    }
    
    // Called from RileyLinkDeviceManager.managerQueue
    init(peripheral: CBPeripheral, centralManager: CBCentralManager, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.central = centralManager
        self.queue = queue

        super.init()

        peripheral.delegate = self

        assertConfiguration()
    }
}

extension PeripheralManager {
    enum CommandCondition {
        case notificationStateUpdate(characteristic: CBCharacteristic, enabled: Bool)
        case valueUpdate(characteristic: CBCharacteristic, matching: ((Data?) -> Bool)?)
        case write(characteristic: CBCharacteristic)
        case discoverServices
        case discoverCharacteristicsForService(serviceUUID: CBUUID)
    }
}

protocol PeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic)
    
    func peripheralManager(_ manager: PeripheralManager, didUpdateNotificationStateFor characteristic: CBCharacteristic)

    func peripheralManager(_ manager: PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?)

    func peripheralManagerDidUpdateName(_ manager: PeripheralManager)

    func completeConfiguration(for manager: PeripheralManager) throws
}

extension PeripheralManager {
    func configureAndRun(_ block: @escaping (_ manager: PeripheralManager) -> Void) -> (() -> Void) {
        return {
            // TODO: Accessing self might be a race on initialization
            if !self.needsConfiguration && self.peripheral.services == nil {
                self.log.error("Configured peripheral has no services. Reconfiguring…")
            }
            
            if self.needsConfiguration || self.peripheral.services == nil {
                do {
                    try self.applyConfiguration()
                    self.log.default("Peripheral configuration completed")
                } catch let error {
                    self.log.error("Error applying peripheral configuration: %@", String(describing: error))
                    // Will retry
                }

                do {
                    if let delegate = self.delegate {
                        try delegate.completeConfiguration(for: self)
                        self.log.default("Delegate configuration completed")
                        self.needsConfiguration = false
                    } else {
                        self.log.error("No delegate set for configuration")
                    }
                } catch let error {
                    self.log.error("Error applying delegate configuration: %@", String(describing: error))
                    // Will retry
                }
            }

            block(self)
        }
    }

    func perform(_ block: @escaping (_ manager: PeripheralManager) -> Void) {
        queue.async(execute: configureAndRun(block))
    }

    private func assertConfiguration() {
        if peripheral.state == .connected {
            perform { (_) in
                // Intentionally empty to trigger configuration if necessary
            }
        }
    }

    private func applyConfiguration(discoveryTimeout: TimeInterval = 2) throws {
        try discoverServices([serviceUUID], timeout: discoveryTimeout)

        guard let service = peripheral.services?.itemWithUUID(serviceUUID) else {
            throw PeripheralManagerError.serviceNotFound
        }

        try discoverCharacteristics([cmdCharacteristicUUID, dataCharacteristicUUID], for: service, timeout: discoveryTimeout)

        guard let characteristic = service.characteristics?.itemWithUUID(cmdCharacteristicUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }
        cmdCharacteristic = characteristic
        try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)

        guard let characteristic = service.characteristics?.itemWithUUID(dataCharacteristicUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }
        dataCharacteristic = characteristic
        try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)
    }
}

//extension PeripheralManager {
//    var timerTickEnabled: Bool {
//        return peripheral.getCharacteristicWithUUID(.timerTick)?.isNotifying ?? false
//    }
//
//    func setTimerTickEnabled(_ enabled: Bool, timeout: TimeInterval = expectedMaxBLELatency, completion: ((_ error: RileyLinkDeviceError?) -> Void)? = nil) {
//        perform { (manager) in
//            do {
//                guard let characteristic = manager.peripheral.getCharacteristicWithUUID(.timerTick) else {
//                    throw PeripheralManagerError.unknownCharacteristic
//                }
//
//                try manager.setNotifyValue(enabled, for: characteristic, timeout: timeout)
//                completion?(nil)
//            } catch let error as PeripheralManagerError {
//                completion?(.peripheralManagerError(error))
//            } catch {
//                assertionFailure()
//            }
//        }
//    }
//
//    func startIdleListening(idleTimeout: TimeInterval, channel: UInt8, timeout: TimeInterval = expectedMaxBLELatency, completion: @escaping (_ error: RileyLinkDeviceError?) -> Void) {
//        perform { (manager) in
//            let command = GetPacket(listenChannel: channel, timeoutMS: UInt32(clamping: Int(idleTimeout.milliseconds)))
//
//            do {
//                try manager.writeCommandWithoutResponse(command, timeout: timeout)
//                completion(nil)
//            } catch let error as RileyLinkDeviceError {
//                completion(error)
//            } catch {
//                assertionFailure()
//            }
//        }
//    }
//
//}

extension PeripheralManager {
    
    /// - Throws: PeripheralManagerError
    func writeCommand(_ value: Data, type: CBCharacteristicWriteType = .withResponse, timeout: TimeInterval) throws {
        perform { [weak self] (manager) in
            guard let characteristic = self?.cmdCharacteristic else {
                return
            }
            try? self?.writeValue(value, characteristic: characteristic, type: type, timeout: timeout)
        }
    }

    /// - Throws: PeripheralManagerError
    func readCommand(timeout: TimeInterval, completion: @escaping (Data?) -> Void) {
        perform { [weak self] (manager) in
            guard let characteristic = self?.cmdCharacteristic else {
                completion(nil)
                return
            }

            do {
                guard let data = try self?.readValue(characteristic: characteristic, timeout: timeout) else {
                    completion(nil)
                    return
                }
                
                completion(data)
            } catch {
                completion(nil)
                return
            }
        }
    }


    /// - Throws: PeripheralManagerError
    func sendCommandType(_ command: PodCommand) {
        guard let characteristic = cmdCharacteristic else {
            return
        }
        try? writeValue(Data([command.rawValue]), characteristic: characteristic, type: .withResponse, timeout: 2)
    }
    
    func expectCommandType(_ command: PodCommand) {
        try? runCommand(timeout: 2) {
            guard let characteristic = cmdCharacteristic else {
                return
            }

            addCondition(.valueUpdate(characteristic: characteristic, matching: { value in
                guard let value = value, value.count > 0 else {
                    return false
                }
                
                guard let response = PodCommand(rawValue: value[0]) else {
                    return false
                }
                
                if response != command {
                    return false
                }
                
                return true
            }))
        }
    }
    
    func peekForNack() -> Bool {
        print("Peek for nack")
        guard let characteristic = cmdCharacteristic else {
            return true
        }

        guard let value = characteristic.value, value.count > 0 else {
            return true
        }
        
        guard let response = PodCommand(rawValue: value[0]) else {
            return true
        }

        return response != PodCommand.NACK
    }
    
    func sendData(_ value: Data, timeout: TimeInterval) {
        guard let characteristic = dataCharacteristic else {
            return
        }
        try? writeValue(value, characteristic: characteristic, type: .withResponse, timeout: timeout)
    }

    func readData(timeout: TimeInterval) -> Data? {
        guard let characteristic = dataCharacteristic else { return Data() }

        return try? readValue(characteristic: characteristic, timeout: timeout)
    }
    
    func sendHello(_ controllerId: Data) {
        perform { [weak self] _ in
            try? self?.writeCommand(Data([PodCommand.HELLO.rawValue]) + Data([0x01, 0x04]) + controllerId, type: .withResponse, timeout: 2)
        }
    }

    func sendCommand(_ command: MessagePacket, _ forEncryption: Bool = false) -> MessageResult {
        let group = DispatchGroup()
        let result: MessageResult = MessageSendSuccess()
        
        group.enter()
        perform { [weak self] _ in
            self?.sendCommandType(PodCommand.RTS)
            self?.expectCommandType(PodCommand.CTS)
            
            let splitter = PayloadSplitter(payload: command.asData(forEncryption: forEncryption))
            let packets = splitter.splitInPackets()

            for packet in packets {
                self?.sendData(packet.toData(), timeout: 2)
            }
            
            self?.expectCommandType(PodCommand.SUCCESS)
            group.leave()
            // TODO:
//            self?.expectCommandType(PodCommand.NACK) {
//                result = MessageSendFailure()
//                self?.flushConditions()
//                group.leave()
//            }
        }
        group.wait()
        return result
    }
    
    func receiveCommand(_ readRTS: Bool = true) throws -> MessagePacket? {
        var packet: MessagePacket?
        perform { [weak self] _ in
            if (readRTS) {
                self?.expectCommandType(PodCommand.RTS)
            }
            self?.sendCommandType(PodCommand.CTS)

    //          readReset()
            var expected: UInt8 = 0
    //          try {
            let firstPacket = self?.readData(timeout: 2)
            print("Reading First Packet")
            print(firstPacket)
//            packet = try? MessagePacket.parse(payload: dataCharacteristic.value)
    //              let firstPacket = expectBlePacket(0)
    //              if (firstPacket !is PacketReceiveSuccess) {
    //                  aapsLogger.warn(LTag.PUMPBTCOMM, "Error reading first packet:$firstPacket")
    //                  return null
    //              }
    //              let joiner = PayloadJoiner(firstPacket.payload)
    //              maxMessageReadTries = joiner.fullFragments * 2 + 2
    //              for (i in 1 until joiner.fullFragments + 1) {
    //                  expected++
    //                  let nackOnTimeout = !joiner.oneExtraPacket && i == joiner.fullFragments // last packet
    //                  let packet = expectBlePacket(expected, nackOnTimeout)
    //                  if (packet !is PacketReceiveSuccess) {
    //                      aapsLogger.warn(LTag.PUMPBTCOMM, "Error reading packet:$packet")
    //                      return null
    //                  }
    //                  joiner.accumulate(packet.payload)
    //              }
    //              if (joiner.oneExtraPacket) {
    //                  expected++
    //                  let packet = expectBlePacket(expected, true)
    //                  if (packet !is PacketReceiveSuccess) {
    //                      aapsLogger.warn(LTag.PUMPBTCOMM, "Error reading packet:$packet")
    //                      return null
    //                  }
    //                  joiner.accumulate(packet.payload)
    //              }
    //              let fullPayload = joiner.finalize()
    //              cmdBleIO.sendAndConfirmPacket(BleCommandSuccess.data)
    //              return MessagePacket.parse(fullPayload)
    //          } catch (e: IncorrectPacketException) {
    //              aapsLogger.warn(LTag.PUMPBTCOMM, "Received incorrect packet: $e")
    //              cmdBleIO.sendAndConfirmPacket(BleCommandAbort.data)
    //              return null
    //          } catch (e: CrcMismatchException) {
    //              aapsLogger.warn(LTag.PUMPBTCOMM, "CRC mismatch: $e")
    //              cmdBleIO.sendAndConfirmPacket(BleCommandFail.data)
    //              return null
    //          } finally {
    //              readReset()
    //          }
    //          }
            self?.sendCommandType(PodCommand.SUCCESS)
            try? MessagePacket.parse(payload: Data())
        }
        return packet
    }
    //
//    private func peekForNack(index: Int, packets: List<BlePacket>): MessageSendResult {
//        val peekCmd = cmdBleIO.peekCommand()
//            ?: return MessageSendSuccess
//
//        return when (val receivedCmd = BleCommand.parse(peekCmd)) {
//            is BleCommandNack -> {
//                // // Consume NACK
//                val received = cmdBleIO.receivePacket()
//                if (received == null) {
//                    MessageSendErrorSending(received.toString())
//                } else {
//                    val sendResult = dataBleIO.sendAndConfirmPacket(packets[receivedCmd.idx.toInt()].toByteArray())
//                    handleSendResult(sendResult, index, packets)
//                }
//            }
//
//            BleCommandSuccess -> {
//                if (index != packets.size)
//                    MessageSendErrorSending("Received SUCCESS before sending all the data. $index")
//                else
//                    MessageSendSuccess
//            }
//
//            else ->
//                MessageSendErrorSending("Received unexpected command: ${peekCmd.toHex()}")
//        }
//    }

}

extension PeripheralManager {
    /// - Throws: PeripheralManagerError
    func runCommand(timeout: TimeInterval, command: () -> Void) throws {
        // Prelude
        dispatchPrecondition(condition: .onQueue(queue))
        guard central?.state == .poweredOn && peripheral.state == .connected else {
            throw PeripheralManagerError.notReady
        }

        commandLock.lock()

        defer {
            commandLock.unlock()
        }

        guard commandConditions.isEmpty else {
            throw PeripheralManagerError.notReady
        }

        // Run
        command()

        guard !commandConditions.isEmpty else {
            // If the command didn't add any conditions, then finish immediately
            return
        }

        // Postlude
        let signaled = commandLock.wait(until: Date(timeIntervalSinceNow: timeout))

        defer {
            commandError = nil
            commandConditions = []
        }

        guard signaled else {
            throw PeripheralManagerError.timeout(commandConditions)
        }

        if let error = commandError {
            throw PeripheralManagerError.cbPeripheralError(error)
        }
    }

    /// It's illegal to call this without first acquiring the commandLock
    ///
    /// - Parameter condition: The condition to add
    func addCondition(_ condition: CommandCondition) {
        dispatchPrecondition(condition: .onQueue(queue))
        commandConditions.append(condition)
    }
    
    func flushConditions() {
        commandConditions.removeAll()
    }

    func discoverServices(_ serviceUUIDs: [CBUUID], timeout: TimeInterval) throws {
        let servicesToDiscover = peripheral.servicesToDiscover(from: serviceUUIDs)

        guard servicesToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout) {
            addCondition(.discoverServices)

            peripheral.discoverServices(serviceUUIDs)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID], for service: CBService, timeout: TimeInterval) throws {
        let characteristicsToDiscover = peripheral.characteristicsToDiscover(from: characteristicUUIDs, for: service)

        guard characteristicsToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout) {
            addCondition(.discoverCharacteristicsForService(serviceUUID: service.uuid))

            peripheral.discoverCharacteristics(characteristicsToDiscover, for: service)
        }
    }

    /// - Throws: PeripheralManagerError
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            addCondition(.notificationStateUpdate(characteristic: characteristic, enabled: enabled))

            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    /// - Throws: PeripheralManagerError
    func readValue(characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data? {
        try runCommand(timeout: timeout) {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))

            peripheral.readValue(for: characteristic)
        }

        return characteristic.value
    }


    /// - Throws: PeripheralManagerError
    func writeValue(_ value: Data, characteristic: CBCharacteristic, type: CBCharacteristicWriteType, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            peripheral.writeValue(value, for: characteristic, type: type)
        }
    }
}

extension PeripheralManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverServices = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverCharacteristicsForService(serviceUUID: service.uuid) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .notificationStateUpdate(characteristic: characteristic, enabled: characteristic.isNotifying) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
        delegate?.peripheralManager(self, didUpdateNotificationStateFor: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()
        
        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .write(characteristic: characteristic) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()
        
        var notifyDelegate = false

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .valueUpdate(characteristic: characteristic, matching: let matching) = condition {
                return matching?(characteristic.value) ?? true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        } else {
            notifyDelegate = true // execute after the unlock
        }

        commandLock.unlock()

        if notifyDelegate {
            // If we weren't expecting this notification, pass it along to the delegate
            delegate?.peripheralManager(self, didUpdateValueFor: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        delegate?.peripheralManager(self, didReadRSSI: RSSI, error: error)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        delegate?.peripheralManagerDidUpdateName(self)
    }
}


extension PeripheralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            assertConfiguration()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        switch peripheral.state {
        case .connected:
            assertConfiguration()
        default:
            break
        }
    }
}

extension PeripheralManager {
    
    public override var debugDescription: String {
        var items = [
            "## PeripheralManager",
            "peripheral: \(peripheral)"
        ]
        queue.sync {
            items.append("needsConfiguration: \(needsConfiguration)")
        }
        return items.joined(separator: "\n")
    }
}

extension CBPeripheral {
    func servicesToDiscover(from serviceUUIDs: [CBUUID]) -> [CBUUID] {
        let knownServiceUUIDs = services?.compactMap({ $0.uuid }) ?? []
        return serviceUUIDs.filter({ !knownServiceUUIDs.contains($0) })
    }

    func characteristicsToDiscover(from characteristicUUIDs: [CBUUID], for service: CBService) -> [CBUUID] {
        let knownCharacteristicUUIDs = service.characteristics?.compactMap({ $0.uuid }) ?? []
        return characteristicUUIDs.filter({ !knownCharacteristicUUIDs.contains($0) })
    }

//    func getCharacteristicWithUUID(_ uuid: MainServiceCharacteristicUUID, serviceUUID: RileyLinkServiceUUID = .main) -> CBCharacteristic? {
//        guard let service = services?.itemWithUUID(serviceUUID.cbUUID) else {
//            return nil
//        }
//
//        return service.characteristics?.itemWithUUID(uuid.cbUUID)
//    }
}


extension Collection where Element: CBAttribute {
    func itemWithUUID(_ uuid: CBUUID) -> Element? {
        for attribute in self {
            if attribute.uuid == uuid {
                return attribute
            }
        }

        return nil
    }
}
