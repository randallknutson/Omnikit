//
//  ViewController.swift
//  OpenPodSDK
//
//  Created by Randall Knutson on 7/31/21.
//

import UIKit

class ViewController: UIViewController {
    var podKit: PodKit!
    var device: PodDevice?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        print("Start");
        
        NotificationCenter.default.addObserver(self, selector: #selector(onDidRecieveData(_:)), name: .ManagerDevicesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceConnectionStateDidChange(_:)), name: .DeviceConnectionStateDidChange, object: nil)
        
        podKit = PodKit()
        podKit.bluetoothManager.setScanningEnabled(true)

    }

    @IBAction func PairTouched2(_ sender: Any) {
        print("Touch")
        guard let device = device else { return }
        try? podKit.pair(device)
    }
    
    @objc func onDidRecieveData(_ notification: Notification) {
        guard let manager = notification.object as? BluetoothManager else { return }
        podKit.connect()
    }
    
    @objc func deviceConnectionStateDidChange(_ notification: Notification) {
        guard let newDevice = notification.object as? PodDevice else { return }
        device = newDevice
    }
}
