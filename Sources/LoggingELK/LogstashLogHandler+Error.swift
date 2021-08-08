//
//  LogstashLogHandler+Error.swift
//
//  Created by Philipp Zagar on 23.07.21.
//

import Foundation

extension LogstashLogHandler {
    enum Error: String {
        case backgroundActivityLoggerBackendError = """
        Background Activity Logger uses the LogstashLogHandler as a logging backend. \
        This results in an infinite recursion in case of an error in the logging backend.
        """
        
        case maximumLogStorageSizeTooLow = """
        The passed maximumLogStorageSize is too low. It needs to be at least twice as much \
        (spoken in terms of the power of two) as the passed minimumLogStorageSize.
        """
        
        case notYetSetup = """
        The static .setup() function must be called before the LogstashLogHandler is intialized
        via LoggingSystem.bootrap(...). \
        The reason for that is the Background Activity Logger which can't use the LogstashLogHandler \
        as a backend because it would result in an infinite recursion in case of an error.
        """
    }
}
