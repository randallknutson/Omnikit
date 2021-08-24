//
//  PairResult.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/4/21.
//

import Foundation

struct PairResult {
    var ltk: Data // {
    // TODO:
    // require(ltk.size == 16) { "LTK length must be 16 bytes. Received LTK: ${ltk.toHex()}" }
//        set { // `set throws` only supported in swift 5.5
//            guard newValue.count == 16 else { throw BLEErrors.InvalidLTKKey("Invalid Key, got \(newValue)")}
//        }
//        get {}
//    }
    var msgSeq: UInt8
}
