//
//  SmurfPeripheralProfile.swift
//
//
//  Created by chen on 2024/9/7.
//

import Foundation
import CoreBluetooth

/// Peripheral 規格。
public struct SmurfPeripheralProfile {
    /// 廣播 `CBUUID`。
    public var advertisement: CBUUID
    /// 服務。
    public var services: [SmurfPeripheralService]?
    
    /// 建立 `SmurfPeripheralProfile`。
    ///
    /// - Parameters:
    ///     - advertisement: 廣播 `CBUUID`。
    ///     - services: 服務。
    public init(_ advertisement: CBUUID, services: [SmurfPeripheralService]? = nil) {
        self.advertisement = advertisement
        self.services = services
    }
}
