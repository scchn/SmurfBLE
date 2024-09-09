//
//  SmurfCentralManager.swift
//
//
//  Created by chen on 2024/9/7.
//

import Foundation
import CoreBluetooth

/// `SmurfCentralManager` 錯誤。
public enum SmurfCentralManagerError: Error {
    /// 無效的狀態。
    case invalidState
    /// 連線被取消。
    case connectionCanceled
    /// 連線逾時。
    case connectionTimedOut
    /// 底層連線錯誤。
    case internalConnectionError(Error)
    /// 未知的錯誤。
    case unknown
}

extension SmurfCentralManager {
    private typealias SmurfIdentifier = UUID
    
    private class ConnectionContext {
        var timeoutTimer: Timer
        var completionHandler: (Result<SmurfPeripheral, SmurfCentralManagerError>) -> Void
        
        deinit {
            timeoutTimer.invalidate()
        }
        
        init(timeoutTimer: Timer, completionHandler: @escaping (Result<SmurfPeripheral, SmurfCentralManagerError>) -> Void) {
            self.timeoutTimer = timeoutTimer
            self.completionHandler = completionHandler
        }
    }
    
    /// 搜尋事件類型。
    public enum DiscoveryEventType {
        /// 新裝置。
        case new
        /// 裝置資訊更新。
        case update
    }
    
    /// Peripheral 過濾器。
    public struct PeripheralFilter: Sendable {
        /// 允許所有 Peripheral。
        public static let allowAll = PeripheralFilter { _, _, _ in
            true
        }
        
        /// 搜尋 RSSI 在指定範圍內且可接受連線的 Peripheral。
        static func connectable(minRSSI: Int = -75, maxRSSI: Int = -20) -> Self {
            .init { _, advertisementData, RSSI in
                let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false
                
                return isConnectable && (minRSSI...maxRSSI).contains(RSSI)
            }
        }
        
        private let filter: @Sendable (CBPeripheral, [String: Any], Int) -> Bool
        
        public init(_ filter: @escaping @Sendable (CBPeripheral, [String: Any], Int) -> Bool) {
            self.filter = filter
        }
        
        func isPeripheralMatched(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: Int) -> Bool {
            filter(peripheral, advertisementData, rssi)
        }
    }
}

/// Central Manager。
public class SmurfCentralManager: NSObject, @unchecked Sendable {
    private let centralManager = CBCentralManager()
    private var peripheralFilter: PeripheralFilter = .allowAll
    private var discoveryHandler: ((SmurfPeripheral, DiscoveryEventType) -> Void)?
    private var connectionContexts: [SmurfIdentifier: ConnectionContext] = [:]
    
    /// 狀態。
    public var state: CBManagerState {
        centralManager.state
    }
    /// 是否正在掃描。
    public var isScanning: Bool {
        centralManager.isScanning
    }
    /// 目前搜尋的 Peripheral 規格。
    public private(set) var peripheralProfiles: [SmurfPeripheralProfile]?
    /// 搜尋到的 Peripheral。
    public private(set) var peripherals: [SmurfPeripheral] = []
    /// 狀態變更事件。
    public var stateUpdateHandler: ((CBManagerState) -> Void)? {
        didSet {
            stateUpdateHandler?(state)
        }
    }
    /// Peripheral 斷線事件。
    ///
    /// 因呼叫 ``cancelPeripheralConnection(_:)`` 而中斷的連線錯誤為 `nil`。
    public var peripheralDisconnectionHandler: ((SmurfPeripheral, Error?) -> Void)?
    
    /// 建立 `SmurfManager`。
    public override init() {
        super.init()
        
        centralManager.delegate = self
    }
    
    // MARK: - 掃描
    
    /// 開始掃描 Peripheral。
    ///
    /// 開始掃描後再次呼叫此方法時會先停止前一次的掃描並且取消所有連線後才開始掃描。
    ///
    /// - Parameters:
    ///     - profiles: 需掃描的 Peripheral 規格，預設為 `nil`。
    ///     - filter: Peripheral 過濾器，預設為 ``PeripheralFilter/allowAll``。
    ///     - discoveryHandler: 搜尋事件，參數為 Peripheral 與搜尋事件類型。
    @discardableResult
    public func scan(
        for profiles: [SmurfPeripheralProfile]? = nil,
        filter: PeripheralFilter = .allowAll,
        discoveryHandler: @escaping (SmurfPeripheral, DiscoveryEventType) -> Void
    ) -> Bool {
        guard centralManager.state == .poweredOn else {
            return false
        }
        
        // 停止搜尋並取消所有連線
        
        stopScan()
        
        while let smurfPeripheral = peripherals.popLast() {
            cancelPeripheralConnection(smurfPeripheral)
        }
        
        // 設定新的掃描條件並開始搜尋
        
        self.peripheralProfiles = profiles
        self.peripheralFilter = filter
        self.discoveryHandler = discoveryHandler
        
        let services: [CBUUID]? = if let profiles, !profiles.isEmpty {
            profiles.map(\.advertisement)
        } else {
            nil
        }
        
        centralManager.scanForPeripherals(withServices: services)
        
        return true
    }
    
    public func stopScan() {
        guard centralManager.isScanning else {
            return
        }
        
        discoveryHandler = nil
        centralManager.stopScan()
    }
    
    // MARK: - 連線
    
    /// 連線 Peripheral，如果有正在嘗試的連線則會取消先前的連線。
    ///
    /// - Parameters:
    ///     - smurf: Peripheral。
    ///     - timeoutInterval: 連線逾時秒數，預設為 `60`。
    ///     - completionHandler: 連線完成事件。
    public func connect(
        _ peripheral: SmurfPeripheral,
        timeoutInterval: TimeInterval = 60,
        completionHandler: @escaping (Result<SmurfPeripheral, SmurfCentralManagerError>) -> Void
    ) {
        internalCancelPeripheralConnection(peripheral, wasTimedOut: false)
        
        let timer = Timer(timeInterval: timeoutInterval, repeats: false) { [weak self, weak peripheral] _ in
            guard let self, let peripheral else {
                return
            }
            
            internalCancelPeripheralConnection(peripheral, wasTimedOut: true)
        }
        
        connectionContexts[peripheral.identifier] = .init(timeoutTimer: timer, completionHandler: completionHandler)
        
        RunLoop.main.add(timer, forMode: .common)
        
        centralManager.connect(peripheral.peripheral)
    }
    
    private func internalCancelPeripheralConnection(_ peripheral: SmurfPeripheral, wasTimedOut: Bool) {
        guard let context = connectionContexts.removeValue(forKey: peripheral.identifier) else {
            return
        }
        
        context.completionHandler(.failure(wasTimedOut ? .connectionTimedOut : .connectionCanceled))
        centralManager.cancelPeripheralConnection(peripheral.peripheral)
    }
    
    /// 取消與 Peripheral 的連線。
    ///
    /// - Parameter peripheral: 嘗試連線或是已連線的 Peripheral。
    public func cancelPeripheralConnection(_ peripheral: SmurfPeripheral) {
        internalCancelPeripheralConnection(peripheral, wasTimedOut: false)
    }
}

extension SmurfCentralManager {
    private func findSmurf(peripheral: CBPeripheral) -> SmurfPeripheral? {
        peripherals.first { smurfPeripheral in
            smurfPeripheral.peripheral == peripheral
        }
    }
}

extension SmurfCentralManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateUpdateHandler?(central.state)
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let smurfPeripheral = findSmurf(peripheral: peripheral) {
            discoveryHandler?(smurfPeripheral, .update)
            return
        }
        
        guard peripheralFilter.isPeripheralMatched(peripheral, advertisementData: advertisementData, rssi: RSSI.intValue),
              let advertisements = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        else {
            return
        }
        
        let services = peripheralProfiles?
            .first { profile in
                advertisements.contains(profile.advertisement)
            }?
            .services
        let smurfPeripheral = SmurfPeripheral(peripheral: peripheral, advertisements: advertisements, desiredServices: services)
        
        peripherals.append(smurfPeripheral)
        discoveryHandler?(smurfPeripheral, .new)
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let context = connectionContexts.removeValue(forKey: peripheral.identifier),
              let smurfPeripheral = findSmurf(peripheral: peripheral)
        else {
            return
        }
        
        smurfPeripheral.discoverDesiredServices()
        
        context.completionHandler(.success(smurfPeripheral))
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard let context = connectionContexts.removeValue(forKey: peripheral.identifier) else {
            return
        }
        
        if let error {
            context.completionHandler(.failure(.internalConnectionError(error)))
        } else {
            context.completionHandler(.failure(.unknown))
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard let index = peripherals.firstIndex(where: { $0.peripheral == peripheral }) else {
            return
        }
        
        let smurfPeripheral = peripherals[index]
        
        if error != nil {
            peripherals.remove(at: index)
        }
        
        smurfPeripheral.didDisconnect()
        peripheralDisconnectionHandler?(smurfPeripheral, error)
    }
}
