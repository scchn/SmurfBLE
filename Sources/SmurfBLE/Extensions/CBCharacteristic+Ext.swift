//
//  CBCharacteristic+Ext.swift
//
//
//  Created by chen on 2024/9/7.
//

import Foundation
import CoreBluetooth

extension CBCharacteristic {
    var availableWriteTypes: [CBCharacteristicWriteType] {
        (properties.contains(.write) ? [.withResponse] : []) +
        (properties.contains(.writeWithoutResponse) ? [.withoutResponse] : [])
    }
}
