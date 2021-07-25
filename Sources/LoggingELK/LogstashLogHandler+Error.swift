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
        
        case maximumLogStorageSizeTooLow = """
        The passed maximumLogStorageSize is too low. It needs to be at least twice as much \
        (spoken in terms of the power of two) as the passed minimumLogStorageSize.
        """
        
        public var errorDescription: String? { self.rawValue }
    }
}
