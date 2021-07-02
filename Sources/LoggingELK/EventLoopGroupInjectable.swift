//
//  EventLoopGroupInjectable.swift
//  
//
//  Created by Philipp Zagar on 01.07.21.
//

import Foundation
import NIO

public protocol EventLoopGroupInjectable {
    func inject(eventLoopGroup: EventLoopGroup)
}
