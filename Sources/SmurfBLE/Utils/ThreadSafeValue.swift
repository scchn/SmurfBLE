//
//  ThreadSafeValue.swift
//
//
//  Created by chen on 2024/9/8.
//

import Foundation
import os

class ThreadSafeValue<T>: @unchecked Sendable where T: Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: T
    
    init(initialValue: T) {
        self.value = initialValue
    }
    
    func set(_ value: T) {
        lock.withLock {
            self.value = value
        }
    }
    
    func get() -> T {
        lock.withLock {
            self.value
        }
    }
}
