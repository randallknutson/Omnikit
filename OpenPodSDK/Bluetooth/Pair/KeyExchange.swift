//
//  KeyExchange.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/3/21.
//

import Foundation
import CryptoKit

class KeyExchange {
    static let CMAC_SIZE = 16

    static let PUBLIC_KEY_SIZE = 32
    static let NONCE_SIZE = 16

    private let INTERMEDIARY_KEY_MAGIC_STRING = "TWIt".data(using: .utf8)
    private let PDM_CONF_MAGIC_PREFIX = "KC_2_U".data(using: .utf8)
    private let POD_CONF_MAGIC_PREFIX = "KC_2_V".data(using: .utf8)

    let pdmNonce: Data
    let pdmPrivate: Data
    let pdmPublic: Data
    var podPublic: Data
    var podNonce: Data
    let podConf: Data
    let pdmConf: Data
    var ltk: Data
    
    private let x25519: X25519KeyGenerator
    let randomByteGenerator: RandomByteGenerator
    
    init(_ x25519: X25519KeyGenerator, _ randomByteGenerator: RandomByteGenerator) throws {
        self.x25519 = x25519
        self.randomByteGenerator = randomByteGenerator
        
        pdmNonce = randomByteGenerator.nextBytes(length: KeyExchange.NONCE_SIZE)
        pdmPrivate = x25519.generatePrivateKey()
        pdmPublic = try x25519.publicFromPrivate(pdmPrivate)
    
        podPublic = Data(capacity: KeyExchange.PUBLIC_KEY_SIZE)
        podNonce = Data(capacity: KeyExchange.NONCE_SIZE)
    
        podConf = Data(capacity: KeyExchange.CMAC_SIZE)
        pdmConf = Data(capacity: KeyExchange.CMAC_SIZE)
    
        ltk = Data(capacity: KeyExchange.CMAC_SIZE)
    }

    func updatePodPublicData(_ payload: Data) throws {
        if (payload.count != KeyExchange.PUBLIC_KEY_SIZE + KeyExchange.NONCE_SIZE) {
            throw BLEErrors.MessageIOException("Invalid payload size")
        }
        podPublic = payload.subdata(in: 0..<KeyExchange.PUBLIC_KEY_SIZE)
        podNonce = payload.subdata(in: KeyExchange.PUBLIC_KEY_SIZE..<KeyExchange.PUBLIC_KEY_SIZE + KeyExchange.NONCE_SIZE)
        try generateKeys()
    }

    func validatePodConf(_ payload: Data) throws {
        if (podConf != payload) {
//            aapsLogger.warn(
//                LTag.PUMPBTCOMM,
//                "Received invalid podConf. Expected: ${podConf.toHex()}. Got: ${payload.toHex()}"
//            )
            throw BLEErrors.MessageIOException("Invalid podConf value received")
        }
    }

    private func generateKeys() throws  {
        let curveLTK = try x25519.computeSharedSecret(pdmPrivate, podPublic)

        let firstKey = podPublic.subdata(in: podPublic.count - 4..<podPublic.count) +
            pdmPublic.subdata(in: pdmPublic.count - 4..<pdmPublic.count) +
            podNonce.subdata(in: podNonce.count - 4..<podNonce.count) +
            pdmNonce.subdata(in: pdmNonce.count - 4..<pdmNonce.count)
//        aapsLogger.debug(LTag.PUMPBTCOMM, "First key for LTK: ${firstKey.toHex()}")

        let intermediateKey = Data(count: KeyExchange.CMAC_SIZE)
        // TODO: 
//        aesCmac(firstKey, curveLTK, intermediateKey)
        aesCmac(firstKey, Data(), intermediateKey)

        let ltkData = Data([0x02]) +
            INTERMEDIARY_KEY_MAGIC_STRING! +
            podNonce +
            pdmNonce +
            Data([0x00, 0x01])
        aesCmac(intermediateKey, ltkData, ltk)

        let confData = Data([0x01]) +
            INTERMEDIARY_KEY_MAGIC_STRING! +
            podNonce +
            pdmNonce +
            Data([0x00, 0x01])
        let confKey = Data(count: KeyExchange.CMAC_SIZE)
        aesCmac(intermediateKey, confData, confKey)

        let pdmConfData = PDM_CONF_MAGIC_PREFIX! +
            pdmNonce +
            podNonce
        aesCmac(confKey, pdmConfData, pdmConf)
//        aapsLogger.debug(LTag.PUMPBTCOMM, "pdmConf: ${pdmConf.toHex()}")

        let podConfData = POD_CONF_MAGIC_PREFIX! +
            podNonce +
            pdmNonce
        aesCmac(confKey, podConfData, podConf)
//        aapsLogger.debug(LTag.PUMPBTCOMM, "podConf: ${podConf.toHex()}")

//        if (BuildConfig.DEBUG) {
//            aapsLogger.debug(LTag.PUMPBTCOMM, "pdmPrivate: ${pdmPrivate.toHex()}")
//            aapsLogger.debug(LTag.PUMPBTCOMM, "pdmPublic: ${pdmPublic.toHex()}")
//            aapsLogger.debug(LTag.PUMPBTCOMM, "podPublic: ${podPublic.toHex()}")
//            aapsLogger.debug(LTag.PUMPBTCOMM, "pdmNonce: ${pdmNonce.toHex()}")
//            aapsLogger.debug(LTag.PUMPBTCOMM, "podNonce: ${podNonce.toHex()}")
//
//            aapsLogger.debug(LTag.PUMPBTCOMM, "LTK, donna key: ${curveLTK.toHex()}")
//            aapsLogger.debug(LTag.PUMPBTCOMM, "Intermediate key: ${intermediateKey.toHex()}")
//            aapsLogger.debug(LTag.PUMPBTCOMM, "LTK: ${ltk.toHex()}")
//            aapsLogger.debug(LTag.PUMPBTCOMM, "Conf KEY: ${confKey.toHex()}")
//        }
    }
}
//

//
private func aesCmac(_ key: Data, _ data: Data, _ result: Data) {
    // TODO:
//    AES()
//    let aesEngine = AESEngine()
//    let mac = CMac(aesEngine)
//    mac.init(KeyParameter(key))
//    mac.update(data, 0, data.count)
//    mac.doFinal(result, 0)
}
