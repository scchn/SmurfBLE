//
//  Collection+Ext.swift
//
//
//  Created by Rex Chen on 2024/7/12.
//

import Foundation

extension Collection {
    func chunked(into size: Int) -> Chunks<Self> {
        .init(source: self, size: size)
    }
}
