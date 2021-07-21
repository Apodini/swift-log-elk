//
//  LogstashLogHandler+HTTPFormatting.swift
//  
//
//  Created by Philipp Zagar on 15.07.21.
//

import Foundation
import NIO
import Logging
import AsyncHTTPClient

extension LogstashLogHandler {
    /// A struct used to encode the `Logger.Level`, `Logger.Message`, `Logger.Metadata`, and a timestamp
    /// which is then sent to Logstash
    struct LogstashHTTPBody: Codable {
        let timestamp: Date
        let loglevel: Logger.Level
        let message: Logger.Message
        let metadata: Logger.Metadata
    }

    /// The `JSONEncoder` used to encode the `LogstashHTTPBody` to JSON
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
                                                        positiveInfinity: "+inf",
                                                        negativeInfinity: "-inf",
                                                        nan: "NaN"
                                                     )
        return encoder
    }()

    /// Creates the HTTP request which stays constant during the entire lifetime of the `LogstashLogHandler`
    /// Sets some default headers, eg. a dynamically adjusted "Keep-Alive" header
    func createHTTPRequest() -> HTTPClient.Request {
        var httpRequest: HTTPClient.Request

        do {
            httpRequest = try HTTPClient.Request(url: "http://\(hostname):\(port)", method: .POST)
        } catch {
            fatalError("Logstash HTTP Request couldn't be created. Check if the hostname and port are valid. \(error)")
        }

        // Set headers that always stay consistent over all requests
        httpRequest.headers.add(name: "Content-Type", value: "application/json")
        httpRequest.headers.add(name: "Accept", value: "application/json")
        // Keep-alive header to keep the connection open
        httpRequest.headers.add(name: "Connection", value: "keep-alive")
        if uploadInterval <= TimeAmount.seconds(10) {
            httpRequest.headers.add(name: "Keep-Alive",
                                    value: "timeout=\(Int((uploadInterval.rawSeconds * 3).rounded(.toNearestOrAwayFromZero))), max=100")
        } else {
            httpRequest.headers.add(name: "Keep-Alive",
                                    value: "timeout=30, max=100")
        }

        return httpRequest
    }

    /// Encodes the `Logger.Level`, `Logger.Message`, `Logger.Metadata`, and
    /// an automatically created timestamp to a HTTP body in the JSON format
    func encodeLogData(level: Logger.Level,
                       message: Logger.Message,
                       metadata: Logger.Metadata) -> Data? {
        do {
            let bodyObject = LogstashHTTPBody(
                timestamp: Date(),
                loglevel: level,
                message: message,
                metadata: metadata
            )

            return try Self.jsonEncoder.encode(bodyObject)
        } catch {
            return nil
        }
    }
}

//extension LogstashLogHandler {
//    /// Uses the `ISO8601DateFormatter` to create the timstamp of the log entry
//    private var timestamp: String {
//        Self.dateFormatter.string(from: Date())
//    }
//
//    /// An `ISO8601DateFormatter` used to format the timestamp of the log entry in an ISO8601 conformant fashion
//    private static let dateFormatter: ISO8601DateFormatter = {
//        let formatter = ISO8601DateFormatter()
//        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
//        // The identifier en_US_POSIX leads to exception on Linux machines,
//        // on Darwin this is apperently ignored (it's even possible to state an
//        // arbitrary value, no exception is thrown on Darwin machines -> inconsistency?)
//        //formatter.timeZone = TimeZone(identifier: "en_US_POSIX")
//        formatter.timeZone = TimeZone.autoupdatingCurrent
//        return formatter
//    }()
//}

/// Make `Logger.MetadataValue` conform to `Encodable` and `Decodable`, so it can be sent to Logstash
extension Logger.MetadataValue: Codable {
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
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .string("null")
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([Logger.MetadataValue].self) {
            self = .array(array)
        } else if let dictionary = try? container.decode(Logger.Metadata.self) {
            self = .dictionary(dictionary)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Encountered unexpected JSON values")
            )
        }
    }
}

/// Make `Logger.Message` conform to `Encodable` and `Decodable`, so it can be sent to Logstash
extension Logger.Message: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        try container.encode(self.description)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .init(stringLiteral: "null")
        } else if let string = try? container.decode(String.self) {
            self = .init(stringLiteral: string)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Encountered unexpected JSON values")
            )
        }
    }
}
