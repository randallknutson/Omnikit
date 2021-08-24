//
//  LTKExchanger.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/3/21.
//
import Foundation

class LTKExchanger {
    static let GET_POD_STATUS_HEX_COMMAND: Data = Data(hex: "ffc32dbd08030e0100008a")
    // This is the binary representation of "GetPodStatus command"

    static private let SP1 = "SP1="
    static private let SP2 = ",SP2="
    static private let SPS1 = "SPS1="
    static private let SPS2 = "SPS2="
    static private let SP0GP0 = "SP0,GP0"
    static private let P0 = "P0="
    static private let UNKNOWN_P0_PAYLOAD = Data([0xa5])

    private let device: PodDevice
    private let ids: Ids
    private let podAddress = Ids.notActivated()
    private let keyExchange = try! KeyExchange(X25519KeyGenerator(), RandomByteGenerator())
    private var seq: UInt8 = 1
    
    init(device: PodDevice, ids: Ids) {
        self.device = device
        self.ids = ids
    }

    func negotiateLTK() throws -> PairResult {
        print("Sending sp1sp2")
        let sp1sp2 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [LTKExchanger.SP1, LTKExchanger.SP2],
            payloads: ["4241".data(using: .utf8)!, sp2()]
//            payloads: [ids.podId.address, sp2()]
        )
        try throwOnSendError(sp1sp2.messagePacket, LTKExchanger.SP1 + LTKExchanger.SP2)

        seq += 1
        print("Sending sps1")
        let sps1 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [LTKExchanger.SPS1],
            payloads: [keyExchange.pdmPublic + keyExchange.pdmNonce]
        )
        try throwOnSendError(sps1.messagePacket, LTKExchanger.SPS1)

        print("Reading sps1")
        let podSps1 = try device.manager.receiveCommand()
        guard let podSps1 = podSps1 else {
            throw BLEErrors.PairingException("Could not read SPS1")
        }
        try processSps1FromPod(podSps1)
        // now we have all the data to generate: confPod, confPdm, ltk and noncePrefix

        print("Sending sps2")
        seq += 1
        let sps2 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [LTKExchanger.SPS2],
            payloads: [keyExchange.pdmConf]
        )
        try throwOnSendError(sps2.messagePacket, LTKExchanger.SPS2)

        let podSps2 = try device.manager.receiveCommand()
        guard let podSps2 = podSps2 else {
            throw BLEErrors.PairingException("Could not read SPS2")
        }
        try validatePodSps2(podSps2)
        // No exception throwing after this point. It is possible that the pod saved the LTK

        seq += 1
        // send SP0GP0
        let sp0gp0 = PairMessage(
            sequenceNumber: seq,
            source: ids.myId,
            destination: podAddress,
            keys: [LTKExchanger.SP0GP0],
            payloads: []
        )
        let result = device.manager.sendCommand(sp0gp0.messagePacket)
        guard ((result as? MessageSendSuccess) != nil) else {
            throw BLEErrors.PairingException("Error sending SP0GP0: \(result)")
        }

        let p0 = try device.manager.receiveCommand()
        guard let p0 = p0 else {
            throw BLEErrors.PairingException("Could not read P0")
        }
        try validateP0(p0)

        return PairResult(
            ltk: keyExchange.ltk,
            msgSeq: seq
        )
    }

    private func throwOnSendError(_ msg: MessagePacket, _ msgType: String) throws {
        let result = device.manager.sendCommand(msg)
        guard ((result as? MessageSendSuccess) != nil) else {
            throw BLEErrors.PairingException("Could not send or confirm $msgType: \(result)")
        }
    }

    private func processSps1FromPod(_ msg: MessagePacket) throws {
//        aapsLogger.debug(LTag.PUMPBTCOMM, "Received SPS1 from pod: ${msg.payload.toHex()}")

        let payload = try StringLengthPrefixEncoding.parseKeys([LTKExchanger.SPS1], msg.payload)[0]
        try keyExchange.updatePodPublicData(payload)
    }

    private func validatePodSps2(_ msg: MessagePacket) throws {
//        print(LTag.PUMPBTCOMM, "Received SPS2 from pod: ${msg.payload.toHex()}")

        let payload = try StringLengthPrefixEncoding.parseKeys([LTKExchanger.SPS2], msg.payload)[0]
//        aapsLogger.debug(LTag.PUMPBTCOMM, "SPS2 payload from pod: ${payload.toHex()}")

        if (payload.count != KeyExchange.CMAC_SIZE) {
            throw BLEErrors.MessageIOException("Invalid payload size")
        }
        try keyExchange.validatePodConf(payload)
    }

    private func sp2() -> Data {
        // This is GetPodStatus command, with page 0 parameter.
        // We could replace that in the future with the serialized GetPodStatus()
        return LTKExchanger.GET_POD_STATUS_HEX_COMMAND
    }

    private func validateP0(_ msg: MessagePacket) throws {
//        aapsLogger.debug(LTag.PUMPBTCOMM, "Received P0 from pod: ${msg.payload.toHex()}")

        let payload = try StringLengthPrefixEncoding.parseKeys([LTKExchanger.P0], msg.payload)[0]
//        aapsLogger.debug(LTag.PUMPBTCOMM, "P0 payload from pod: ${payload.toHex()}")
        if (payload != LTKExchanger.UNKNOWN_P0_PAYLOAD) {
            throw BLEErrors.PairingException("Reveived invalid P0 payload: \(payload)")
        }
    }
}
