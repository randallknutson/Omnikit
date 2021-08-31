//
//  PodKit.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 8/17/21.
//

import Foundation
import CoreBluetooth

struct PodConfiguration {
    var ltk: Data
    var seq: Int
    var address: String
}

class PodKit {
    let bluetoothManager: BluetoothManager
//    private let configuration: PodConfiguration

    init() {
//        self.configuration = configuration
        bluetoothManager = BluetoothManager(autoConnectIDs: [])
//        bluetoothManager.delegate = self
    }
    
    func connect() {
        print("connect")
        bluetoothManager.getDevices { devices in
            for device in devices {
                if (device.peripheralState != .connected) { 
                    self.bluetoothManager.connect(device)
                }
            }
        }
    }
    
    func pair(_ device: PodDevice) throws {
        print("pair")
        let id = Id.fromInt(CONTROLLER_ID)
        try device.manager.sendHello(id.address)
        
        let ltkExchanger = LTKExchanger(device: device, ids: Ids(podState: PodStateManager(id: 1)))
        let result = try ltkExchanger.negotiateLTK()
        print(result)
    }
}

enum PodKitState {
    case noPod
    case activating
    case deactivating
    case active
    
    static func alarm() {
        
    }
    static func systemError() {
        
    }
}

enum PodKitResult<T> {
    case success(T)
    case failure(Error)
}
