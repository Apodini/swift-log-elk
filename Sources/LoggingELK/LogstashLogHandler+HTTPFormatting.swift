//
//  LogstashLogHandler+HTTPFormatting.swift
//  
//
//  Created by Philipp Zagar on 15.07.21.
//

import Foundation
import Logging
import AsyncHTTPClient

extension LogstashLogHandler {
    private struct LogstashHTTPBody: Encodable {
        let timestamp: String
        let loglevel: Logger.Level
        let message: Logger.Message
        let metadata: Logger.Metadata
    }
    
    internal func createHTTPRequest() -> HTTPClient.Request {
        var httpRequest: HTTPClient.Request
        
        do {
            /// Create the base HTTP Request
            httpRequest = try HTTPClient.Request(url: "http://\(hostname):\(port)", method: .POST)
        } catch {
            fatalError("Logstash HTTP Request couldn't be created. Check if the hostname and port are valid. \(error)")
        }
        
        /// Set headers that always stay consistent over all requests
        httpRequest.headers.add(name: "Content-Type", value: "application/json")
        httpRequest.headers.add(name: "Accept", value: "application/json")
        /// Keep-alive header to keep the connection open
        httpRequest.headers.add(name: "Connection", value: "keep-alive")
        // Maybe make this timeout also configurable
        // Of course the connection shouldn't be open for 3h, configure a threshhold etc.
        httpRequest.headers.add(name: "Keep-Alive", value: "timeout=30, max=120")
        
        return httpRequest
    }
    
    internal func encodeLogData(mergedMetadata: Logger.Metadata, level: Logger.Level, message: Logger.Message) -> Data? {
        do {
            /// Create HTTP Request body
            let bodyObject = LogstashHTTPBody(timestamp: timestamp(),
                                              loglevel: level,
                                              message: message,
                                              metadata: mergedMetadata)
            
            /// Encode body
            return try JSONEncoder().encode(bodyObject)
        } catch {
            return nil
        }
    }
}

/// Make `Logger.MetadataValue` conform to `Encodable`
extension Logger.MetadataValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(string):
            try container.encode(string)
        case let .stringConvertible(stringConvertible):
            try container.encode(stringConvertible.description)
        case let .dictionary(dictionary):
            try container.encode(dictionary)
        case let .array(array):
            try container.encode(array)
        }
    }
}

/// Make `Logger.Message` conform to `Encodable`
extension Logger.Message: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.description)
    }
}


