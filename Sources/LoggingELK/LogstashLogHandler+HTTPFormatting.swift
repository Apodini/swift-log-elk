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
        let message: String
        let metadata: String
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
    
    internal func encodeLogData(unpackedMetadata: [String: Any], level: Logger.Level, message: Logger.Message) -> Data? {
        do {
            /// Encode the metadata to JSON again
            let encodedMetadata = try JSONSerialization.data(withJSONObject: unpackedMetadata, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            
            /// JSON to String
            let stringyfiedMetadata = String(decoding: encodedMetadata, as: UTF8.self)
            //print(stringyfiedMetadata)
            
            /// Create HTTP Request body
            let bodyObject = LogstashHTTPBody(timestamp: timestamp(),
                                              loglevel: level,
                                              message: message.description,
                                              metadata: stringyfiedMetadata)
            
            /// Encode body
            let logData = try JSONEncoder().encode(bodyObject)
            
            /// Debug print
            print("Readable Bytes from Buffer: \(self.byteBuffer.readableBytes)")
            print("Log Data: \(logData.count)")
            print("Buffer Capacity: \(self.byteBuffer.capacity)")
            
            return logData
        } catch {
            return nil
        }
    }
}
