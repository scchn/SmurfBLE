//
//  SmurfPeripheral.swift
//
//
//  Created by chen on 2024/9/7.
//

import Foundation
import CoreBluetooth

/// `SmurfPeripheral` 錯誤。
public enum SmurfPeripheralError: Error {
    /// 無效的服務。
    case invalidService
    /// 不支援的寫入操作類型。
    case unsupportedWriteType
    /// 要寫入的資料為空。
    case emptyWriteValue
    /// 無效的資料分割大小。
    case invalidChunkSize
    /// 動作已被取消。
    case operationCanceled
    /// 寫入操作發生錯誤。
    case internalWriteError(Error)
    /// 連線中斷。
    case disconnected
}

extension SmurfPeripheral {
    private class WriteContext: @unchecked Sendable {
        let id: UUID
        let serviceUUIDString: String
        let characteristic: CBCharacteristic // 只在 Main Thread 使用
        let token: CancellationToken
        let completionHandler: @Sendable (Result<CBCharacteristic, SmurfPeripheralError>) -> Void // 只在 Main Thread 使用
        private(set) var dataChunks: [Data] // 只在 `writeWithResponseQueue` 以及 `writeWithoutResponseQueue` 使用
        
        init(
            id: UUID,
            serviceUUIDString: String,
            characteristic: CBCharacteristic,
            dataChunks: [Data],
            token: CancellationToken,
            completionHandler: @escaping @Sendable (Result<CBCharacteristic, SmurfPeripheralError>) -> Void
        ) {
            self.id = id
            self.serviceUUIDString = serviceUUIDString
            self.characteristic = characteristic
            self.dataChunks = dataChunks
            self.token = token
            self.completionHandler = completionHandler
        }
        
        @discardableResult
        func removeFirstDataChunk() -> Data {
            dataChunks.removeFirst()
        }
    }
    
    /// 取消寫入操作 Token。
    public final class CancellationToken: Sendable {
        private let action: (@Sendable () -> Void)?
        
        init(_ action: (@Sendable () -> Void)?) {
            self.action = action
        }
        
        /// 取消寫入操作。
        public func cancel() {
            action?()
        }
    }
}

/// Peripheral。
public class SmurfPeripheral: NSObject, @unchecked Sendable {
    private let desiredServices: [SmurfPeripheralService]?
    private var isDiscoveringServices: Bool = false
    private let writeWithResponseQueue = DispatchQueue(label: "com.dd3Kit.dd3BLE.Smurf.writeWithResponseQueue")
    private var writeWithResponseContexts: [WriteContext] = []
    private let writeWithoutResponseQueue = DispatchQueue(label: "com.dd3Kit.dd3BLE.Smurf.writeWithoutResponseQueue")
    private var writeWithoutResponseContexts: [WriteContext] = []
    
    let peripheral: CBPeripheral
    
    /// 廣播服務 `CBUUID`。
    public let advertisements: [CBUUID]
    /// 識別。
    public var identifier: UUID {
        peripheral.identifier
    }
    /// 名稱。
    public var name: String {
        peripheral.name ?? ""
    }
    /// 狀態。
    public var state: CBPeripheralState {
        peripheral.state
    }
    /// 服務。
    public var services: [CBService] {
        peripheral.services ?? []
    }
    /// 發現特徵。
    public var characteristicsDiscoveryHandler: ((CBService) -> Void)?
    /// 特徵數值更新。
    public var valueUpdateHandler: ((Result<CBCharacteristic, Error>) -> Void)?
    /// 通知狀態變更。
    public var notifyValueUpdateHandler: ((Result<CBCharacteristic, Error>) -> Void)?
    /// 連線中斷。
    public var disconnectionHandler: (() -> Void)?
    /// 服務已不可用。
    public var servicesInvalidationHandler: (([CBService]) -> Void)?
    
    init(peripheral: CBPeripheral, advertisements: [CBUUID], desiredServices: [SmurfPeripheralService]?) {
        self.peripheral = peripheral
        self.desiredServices = desiredServices
        self.advertisements = advertisements
        
        super.init()
        
        self.peripheral.delegate = self
    }
    
    /// 用於連線後開始搜尋服務，只在 Main Thread 執行。
    func discoverDesiredServices() {
        guard !isDiscoveringServices else {
            return
        }
        
        isDiscoveringServices = true
        
        peripheral.discoverServices(desiredServices?.map(\.uuid))
    }
    
    /// 連線中斷，只在 Main Thread 執行。
    func didDisconnect() {
        isDiscoveringServices = false
        cleanup()
        disconnectionHandler?()
    }
    
    private func cleanup() {
        writeWithResponseQueue.async { [weak self] in
            guard let self else {
                return
            }
            
            let completionHandlers = writeWithResponseContexts.map(\.completionHandler)
            
            writeWithResponseContexts.removeAll()
            
            DispatchQueue.main.async {
                for handler in completionHandlers {
                    handler(.failure(.disconnected))
                }
            }
        }
        
        writeWithoutResponseQueue.async { [weak self] in
            guard let self else {
                return
            }
            
            let completionHandlers = writeWithoutResponseContexts.map(\.completionHandler)
            
            writeWithoutResponseContexts.removeAll()
            
            DispatchQueue.main.async {
                for handler in completionHandlers {
                    handler(.failure(.disconnected))
                }
            }
        }
    }
}

extension SmurfPeripheral {
    /// 取得指定服務中的特徵。
    ///
    /// - Parameters:
    ///   - uuid: 特徵 `CBUUID`。
    ///   - service: 包含目標特徵的服務 `CBUUID`。
    /// - Returns: 成功回傳搜尋到的特徵，否則回傳 `nil`。
    public func findCharacteristic(_ uuid: CBUUID, service: CBUUID) -> CBCharacteristic? {
        services
            .first { $0.uuid == service }?
            .characteristics?
            .first { $0.uuid == uuid }
    }
    
    /// 設定通知狀態。
    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        peripheral.setNotifyValue(enabled, for: characteristic)
    }
    
    /// 讀取特徵數值。
    public func readValue(for characteristic: CBCharacteristic) {
        peripheral.readValue(for: characteristic)
    }
}

extension SmurfPeripheral {
    /// 傳輸需回應的寫入操作。
    ///
    /// - Parameters:
    ///     - value: 要寫入的資料。
    ///     - chunkSize: 資料分割大小，指定為 `nil` 時則使用最大傳輸量。預設為 `nil`。
    ///     - characteristic: 要寫入的特徵。
    ///     - completionHandler: 寫入完成。
    ///
    /// - Returns: 取消操作 Token。
    @discardableResult
    public func writeValueWithResponse(
        _ value: Data,
        chunkSize: Int? = nil,
        for characteristic: CBCharacteristic,
        completionHandler: @escaping @Sendable (Result<CBCharacteristic, SmurfPeripheralError>) -> Void
    ) -> CancellationToken {
        let contextResult = makeWriteContext(
            data: value,
            chunkSize: chunkSize,
            for: characteristic,
            type: .withResponse,
            completionHandler: completionHandler
        )
        
        switch contextResult {
        case let .success(context):
            writeWithResponseQueue.async { [weak self] in
                guard let self else {
                    return
                }
                
                let shouldWrite = writeWithResponseContexts.isEmpty
                
                writeWithResponseContexts.append(context)
                
                if shouldWrite {
                    reallyWriteWithResponse(context: context)
                }
            }
            
            return context.token
            
        case let .failure(error):
            DispatchQueue.main.async {
                completionHandler(.failure(error))
            }
            
            return .init(nil)
        }
    }
    
    /// 只能在 `writeWithResponseQueue` 執行。
    private func reallyWriteWithResponse(context: WriteContext) {
        if !context.dataChunks.isEmpty {
            let data = context.removeFirstDataChunk()
            
            DispatchQueue.main.async {
                self.peripheral.writeValue(data, for: context.characteristic, type: .withResponse)
            }
        } else {
            writeWithResponseContexts.removeFirst()
            
            DispatchQueue.main.async {
                context.completionHandler(.success(context.characteristic))
            }
            
            if let next = writeWithResponseContexts.first {
                reallyWriteWithResponse(context: next)
            }
        }
    }
    
    private func cancelWriteWithResponse(id: UUID) {
        writeWithResponseQueue.async { [weak self] in
            guard let self, let index = writeWithResponseContexts.firstIndex(where: { $0.id == id }) else {
                return
            }
            
            let context = writeWithResponseContexts.remove(at: index)
            
            DispatchQueue.main.async {
                context.completionHandler(.failure(.operationCanceled))
            }
        }
    }
    
    private func cancelWritesWithResponse(by invalidatedServices: [CBService]) {
        writeWithResponseQueue.async { [weak self] in
            guard let self else {
                return
            }
            
            let invalidatedServiceUUIDStrings = invalidatedServices.map(\.uuid.uuidString)
            
            self.writeWithResponseContexts.removeAll { context in
                guard invalidatedServiceUUIDStrings.contains(context.serviceUUIDString) else {
                    return false
                }
                
                DispatchQueue.main.async {
                    context.completionHandler(.failure(.invalidService))
                }
                
                return true
            }
        }
    }
}

extension SmurfPeripheral {
    /// 傳輸不需回應的寫入操作。
    ///
    /// - Parameters:
    ///     - value: 要寫入的資料。
    ///     - chunkSize: 資料分割大小，指定為 `nil` 時則使用最大傳輸量。預設為 `nil`。
    ///     - characteristic: 要寫入的特徵。
    ///     - completionHandler: 寫入完成。
    ///
    /// - Returns: 取消操作 Token。
    @discardableResult
    public func writeValueWithoutResponse(
        _ value: Data,
        chunkSize: Int? = nil,
        for characteristic: CBCharacteristic,
        completionHandler: @escaping @Sendable (Result<CBCharacteristic, SmurfPeripheralError>) -> Void
    ) -> CancellationToken {
        let contextResult = makeWriteContext(
            data: value,
            chunkSize: chunkSize,
            for: characteristic,
            type: .withoutResponse,
            completionHandler: completionHandler
        )
        
        switch contextResult {
        case let .success(context):
            writeWithoutResponseQueue.async { [weak self] in
                guard let self else {
                    return
                }
                
                let shouldWrite = writeWithoutResponseContexts.isEmpty
                
                writeWithoutResponseContexts.append(context)
                
                if shouldWrite {
                    reallyWriteWithoutResponse(context: context)
                }
            }
            
            return context.token
            
        case let .failure(error):
            DispatchQueue.main.async {
                completionHandler(.failure(error))
            }
            
            return .init(nil)
        }
    }
    
    /// 只能在 `writeWithoutResponseQueue` 執行。
    private func reallyWriteWithoutResponse(context: WriteContext) {
        let trySend = ThreadSafeValue(initialValue: true)
        
        while !context.dataChunks.isEmpty, trySend.get() {
            let data = context.dataChunks[0]
            let sema = DispatchSemaphore(value: 0)
            
            DispatchQueue.main.async {
                let canSend = self.peripheral.state == .connected && self.peripheral.canSendWriteWithoutResponse
                
                if canSend {
                    self.peripheral.writeValue(data, for: context.characteristic, type: .withoutResponse)
                }
                
                trySend.set(canSend)
                sema.signal()
            }
            
            sema.wait()
            
            if trySend.get() {
                context.removeFirstDataChunk()
            }
        }
        
        if context.dataChunks.isEmpty {
            writeWithoutResponseContexts.removeFirst()
            
            DispatchQueue.main.async {
                context.completionHandler(.success(context.characteristic))
            }
            
            if let context = writeWithoutResponseContexts.first {
                reallyWriteWithoutResponse(context: context)
            }
        }
    }
    
    private func cancelWriteWithoutResponse(id: UUID) {
        writeWithoutResponseQueue.async { [weak self] in
            guard let self, let index = writeWithoutResponseContexts.firstIndex(where: { $0.id == id }) else {
                return
            }
            
            let context = writeWithoutResponseContexts.remove(at: index)
            
            DispatchQueue.main.async {
                context.completionHandler(.failure(.operationCanceled))
            }
        }
    }
    
    private func cancelWritesWithoutResponse(by invalidatedServices: [CBService]) {
        writeWithoutResponseQueue.async { [weak self] in
            guard let self else {
                return
            }
            
            let invalidatedServiceUUIDStrings = invalidatedServices.map(\.uuid.uuidString)
            
            self.writeWithoutResponseContexts.removeAll { context in
                guard invalidatedServiceUUIDStrings.contains(context.serviceUUIDString) else {
                    return false
                }
                
                DispatchQueue.main.async {
                    context.completionHandler(.failure(.invalidService))
                }
                
                return true
            }
        }
    }
}

extension SmurfPeripheral {
    private func makeWriteContext(
        data: Data,
        chunkSize: Int?,
        for characteristic: CBCharacteristic,
        type: CBCharacteristicWriteType,
        completionHandler: @escaping @Sendable (Result<CBCharacteristic, SmurfPeripheralError>) -> Void
    ) -> Result<WriteContext, SmurfPeripheralError> {
        guard !data.isEmpty else {
            return .failure(.emptyWriteValue)
        }
        guard let serviceUUIDString = characteristic.service?.uuid.uuidString else {
            return .failure(.invalidService)
        }
        guard characteristic.availableWriteTypes.contains(type) else {
            return .failure(.unsupportedWriteType)
        }
        
        let chunkSize = chunkSize ?? peripheral.maximumWriteValueLength(for: type)
        
        guard chunkSize > 0 else {
            return .failure(.invalidChunkSize)
        }
        
        let id = UUID()
        let dataChunks = data
            .chunked(into: chunkSize)
            .map { Data($0) }
        let token = makeCancellationToken(id: id, type: type)
        
        return .success(WriteContext(
            id: id,
            serviceUUIDString: serviceUUIDString,
            characteristic: characteristic,
            dataChunks: dataChunks,
            token: token,
            completionHandler: completionHandler
        ))
    }
    
    private func makeCancellationToken(id: UUID, type: CBCharacteristicWriteType) -> CancellationToken {
        .init { [weak self] in
            guard let self else {
                return
            }
            
            switch type {
            case .withResponse:
                cancelWriteWithResponse(id: id)
            case .withoutResponse:
                cancelWriteWithoutResponse(id: id)
            @unknown default:
                break
            }
        }
    }
}

extension SmurfPeripheral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        for service in peripheral.services ?? [] {
            if let desiredServices = desiredServices?.first(where: { $0.uuid == service.uuid }) {
                peripheral.discoverCharacteristics(desiredServices.characteristics, for: service)
            } else {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        characteristicsDiscoveryHandler?(service)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            valueUpdateHandler?(.failure(error))
        } else {
            valueUpdateHandler?(.success(characteristic))
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            notifyValueUpdateHandler?(.failure(error))
        } else {
            notifyValueUpdateHandler?(.success(characteristic))
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        writeWithResponseQueue.async { [weak self] in
            guard let self, let context = writeWithResponseContexts.first else {
                return
            }
            guard let error else {
                reallyWriteWithResponse(context: context)
                return
            }
            
            writeWithResponseContexts.removeFirst()
            
            DispatchQueue.main.async {
                context.completionHandler(.failure(.internalWriteError(error)))
            }
            
            if let next = writeWithResponseContexts.first {
                reallyWriteWithResponse(context: next)
            }
        }
    }
    
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeWithoutResponseQueue.async { [weak self] in
            guard let self, let context = writeWithoutResponseContexts.first else {
                return
            }
            reallyWriteWithoutResponse(context: context)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        cancelWritesWithResponse(by: invalidatedServices)
        cancelWritesWithoutResponse(by: invalidatedServices)
        
        servicesInvalidationHandler?(invalidatedServices)
        
        peripheral.discoverServices(desiredServices?.map(\.uuid))
    }
}
