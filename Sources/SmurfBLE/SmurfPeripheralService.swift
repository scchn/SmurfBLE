//
//  SmurfPeripheralService.swift
//
//
//  Created by chen on 2024/9/7.
//

import Foundation
import CoreBluetooth

/// Peripheral 服務。
public struct SmurfPeripheralService: Equatable, Hashable {
    /// 服務 `CBUUID`。
    public let uuid: CBUUID
    /// 該服務的特徵 `CBUUID`。
    public let characteristics: [CBUUID]?
    
    /// 建立 `SmurfPeripheralService`。
    ///
    /// - Parameters:
    ///     - uuid: 服務 `CBUUID`。
    ///     - characteristics: 該服務的特徵 `CBUUID`。
    public init(_ uuid: CBUUID, characteristics: [CBUUID]? = nil) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}
