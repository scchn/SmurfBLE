//
//  Chunks.swift
//
//
//  Created by Rex Chen on 2024/7/12.
//

import Foundation

extension Chunks {
    struct Iterator: IteratorProtocol {
        private let source: C
        private let size: Int
        private var start: C.Index
        
        init(source: C, size: Int) {
            self.source = source
            self.size = size
            self.start = source.startIndex
        }
        
        mutating func next() -> [C.Element]? {
            guard start < source.endIndex else {
                return nil
            }
            
            let end = source.index(start, offsetBy: size, limitedBy: source.endIndex) ?? source.endIndex
            let chunk = source[start..<end]
            
            start = end
            
            return Array(chunk)
        }
    }
}

struct Chunks<C>: Sequence
where C: Collection
{
    private let source: C
    private let size: Int
    
    init(source: C, size: Int) {
        self.source = source
        self.size = size
    }
    
    func makeIterator() -> Iterator {
        Iterator(source: source, size: size)
    }
}

extension Chunks: Equatable where C: Equatable {
}

extension Chunks: Hashable where C: Hashable {
}

extension Chunks: Encodable where C: Encodable {
}

extension Chunks: Decodable where C: Decodable {
}

extension Chunks: Sendable where C: Sendable {
}
