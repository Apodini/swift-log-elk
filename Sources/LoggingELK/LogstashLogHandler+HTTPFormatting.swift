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
    private struct LogstashHTTPBody: Encodable {
        let timestamp: String
        let loglevel: Logger.Level
        let message: Logger.Message
        let metadata: Logger.Metadata
    }

    private static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
                                                        positiveInfinity: "+inf",
                                                        negativeInfinity: "-inf",
                                                        nan: "NaN"
                                                     )
        return encoder
    }

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

    func encodeLogData(mergedMetadata: Logger.Metadata,
                       level: Logger.Level,
                       message: Logger.Message) -> Data? {
        do {
            let bodyObject = LogstashHTTPBody(
                timestamp: timestamp,
                loglevel: level,
                message: message,
                metadata: mergedMetadata
            )

            return try Self.jsonEncoder.encode(bodyObject)
        } catch {
            return nil
        }
    }
}

extension LogstashLogHandler {
    private var timestamp: String {
        Self.dateFormatter.string(from: Date())
    }

    private static var dateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "en_US_POSIX")
        return formatter
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
