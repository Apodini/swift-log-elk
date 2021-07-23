//
//  LogstashLogHandler+Error.swift
//
//  Created by Philipp Zagar on 23.07.21.
//

import Foundation

extension LogstashLogHandler {
    enum Error: String, LocalizedError {
        case backgroundActivityLoggerBackendError = """
        Background Activity Logger uses the LogstashLogHandler as a logging backend. \
        This results in an infinite recursion in case of an error in the logging backend.
        """
        
        public var errorDescription: String? { self.rawValue }
    }
}
