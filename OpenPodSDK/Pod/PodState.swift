////
////  PodState.swift
////  OpenPodSDK
////
////  Created by Randall Knutson on 7/31/21.
////
//
import Foundation

class PodStateManager {
    let uniqueId: Int64
    
    init(id: Int64) {
        uniqueId = id
    }
}

enum PodState {
    case uninitialized
    case uidSet
    case engagingClutchDrive
    case clutchDriveEngaged
    case basalProgramRunning
    case priming
    case runningAboveMinVolume
    case unfinalizedBolus
}
