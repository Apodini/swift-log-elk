//
//  TimeAmout+Seconds.swift
//
//  Created by Philipp Zagar on 16.07.21.
//

import NIO

extension TimeAmount {
    public var rawSeconds: Double {
        Double(self.nanoseconds) / Double(1_000_000_000)
    }
}
