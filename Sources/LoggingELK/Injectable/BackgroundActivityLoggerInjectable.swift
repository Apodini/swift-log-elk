//
//  BackgroundActivityLoggerInjectable.swift
//  
//
//  Created by Philipp Zagar on 02.07.21.
//

import Foundation
import Logging

public protocol BackgroundActivityLoggerInjectable {
    func inject(backgroundActivityLogger: Logger)
}
