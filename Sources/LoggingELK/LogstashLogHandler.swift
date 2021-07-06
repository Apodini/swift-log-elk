//
//  LogstashLogHandler.swift
//
//
//  Created by Philipp Zagar on 26.06.21.
//

import Foundation
import NIO
import Logging
import AsyncHTTPClient

/// `LogstashLogHandler` is a simple implementation of `LogHandler` for directing
/// `Logger` output to Logstash via HTTP requests
public struct LogstashLogHandler: LogHandler, EventLoopGroupInjectable, BackgroundActivityLoggerInjectable {
    private struct LogstashHTTPBody: Encodable {
        let post_date: String
        let loglevel: Logger.Level
        let message: String
        let metadata: String
        let source: String
        let file: String
        let function: String
        let line: UInt
    }
    
    private let label: String
    private let hostname: String
    private let port: Int
    private var httpClient: Box<HTTPClient?>? = Box(nil)
    private var eventLoopGroup: Box<EventLoopGroup?>? = Box(nil)
    private var backgroundActivityLogger: Box<Logger?>? = Box(nil)

    public var logLevel: Logger.Level = .info

    private var prettyMetadata: String?
    
    public var metadata = Logger.Metadata() {
        didSet {
            self.prettyMetadata = self.prettify(self.metadata)
        }
    }

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            return self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    internal init(label: String, hostname: String, port: Int, eventLoopGroup: EventLoopGroup?, backgroundActivityLogger: Logger? = nil) {
        self.label = label
        self.hostname = hostname
        self.port = port
        self.eventLoopGroup?.value = eventLoopGroup
        self.backgroundActivityLogger?.value = backgroundActivityLogger
    }
    
    /// Factory that makes a `LogstashLogHandler` to directs its output to Logstash
    public static func logstashOutput(label: String, hostname: String = "127.0.0.1", port: Int = 31311, eventLoopGroup: EventLoopGroup? = nil, backgroundActivityLogger: Logger? = nil) -> LogstashLogHandler {
        // Possibility to just pass the type of the Logger in the configuration, the other configs (port etc.) seperatly
        // Fuck, this isn't possible as well since we don't know the LogstashLogger type in Apodinni
        // BUT: we can put this config in the ApodiniObserve package and then depend on the ELK stuff?
        
        return LogstashLogHandler(label: label, hostname: hostname, port: port, eventLoopGroup: eventLoopGroup, backgroundActivityLogger: backgroundActivityLogger)
    }

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
//        let prettyMetadata = metadata?.isEmpty ?? true
//            ? self.prettyMetadata
//            : self.prettify(self.metadata.merging(metadata!, uniquingKeysWith: { _, new in new }))
//
//        var stream = self.stream
//        stream.write("\(self.timestamp()) \(level) \(self.label) :\(prettyMetadata.map { " \($0)" } ?? "") \(message)\n")
        
        
        if self.httpClient?.value == nil {
            guard let eventLoopGroup = self.eventLoopGroup?.value else {
                guard let backgroundActivityLogger = self.backgroundActivityLogger?.value else {
                    // No eventloop, no logger
                    self.httpClient?.value = HTTPClient(
                        eventLoopGroupProvider: .createNew,
                        configuration: HTTPClient.Configuration()
                    )
                    
                    return
                }

                // No eventloop, exisiting logger
                self.httpClient?.value = HTTPClient(
                    eventLoopGroupProvider: .createNew,
                    configuration: HTTPClient.Configuration(),
                    backgroundActivityLogger: backgroundActivityLogger
                )
                
                return
            }
            
            guard let backgroundActivityLogger = self.backgroundActivityLogger?.value else {
                // Existing eventloop, no logger
                self.httpClient?.value = HTTPClient(
                    eventLoopGroupProvider: .shared(eventLoopGroup),
                    configuration: HTTPClient.Configuration()
                )
                
                return
            }
            
            // Existing eventloop, existing logger
            self.httpClient?.value = HTTPClient(
                eventLoopGroupProvider: .shared(eventLoopGroup),
                configuration: HTTPClient.Configuration(),
                backgroundActivityLogger: backgroundActivityLogger
            )
        }
        
        guard let httpClient = self.httpClient?.value else {
            fatalError("HTTPClient not initialized!")
        }
        
        // Impotant: Take the passed metadata into account (merge it)
        // First option:
        //        let prettyMetadata = metadata?.isEmpty ?? true
        //            ? self.prettyMetadata
        //            : self.prettify(self.metadata.merging(metadata!, uniquingKeysWith: { _, new in new }))
        // Second option:
//        func mergedMetadata(_ metadata: Logger.Metadata?) -> Logger.Metadata {
//            if let metadata = metadata {
//                return self.metadata.merging(metadata, uniquingKeysWith: { _, new in new })
//            } else {
//                return self.metadata
//            }
//        }
        
        do {
            var request = try HTTPClient.Request(url: "http://\(hostname):\(port)", method: .POST)
            request.headers.add(name: "Content-Type", value: "application/json")
            request.headers.add(name: "Accept", value: "application/json")
            // Maybe also a keep-alive header to keep the connection open
            request.headers.add(name: "Connection", value: "keep-alive")
            request.headers.add(name: "Keep-Alive", value: "timeout=300, max=1000")
            
//            let test = try JSONSerialization.data(withJSONObject: self.metadata, options: .prettyPrinted)
//            let stringTest = String(decoding: test, as: UTF8.self)
//            print(stringTest)
            
            let entryMetadata: Logger.Metadata
            if let parameterMetadata = metadata {
                entryMetadata = self.metadata.merging(parameterMetadata) { $1 }
            } else {
                entryMetadata = self.metadata
            }
            
            let json = Self.unpackMetadata(.dictionary(entryMetadata)) as! [String: Any]
            
            if #available(macOS 10.15, *) {
                let entry = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
                
                let stringTest = String(decoding: entry, as: UTF8.self)
                print(stringTest)
                
                let bodyObject = LogstashHTTPBody(post_date: timestamp(),
                                                  loglevel: level,
                                                  message: message.description,
                                                  //metadata: prettyMetadata ?? "",
                                                  metadata: stringTest,
                                                  source: source,
                                                  file: file,
                                                  function: function,
                                                  line: line)
                
                let bodyJSON = try JSONEncoder().encode(bodyObject)
                request.body = .data(bodyJSON)
                
                httpClient.execute(request: request).whenComplete { result in
                    switch result {
                    case .failure(let error):
                        //self.inFlight = false
                        print("Error! - failure to connect - \(error)")
                    case .success(let response):
                        //self.inFlight = false
                        if response.status == .ok {
                            print("Success!")
                        } else {
                            print("Error! - \(String(describing: response.status))")
                        }
                    }
                }
            } else {
                print("Houston, We have a problem!")
                return
            }
        } catch {
            print("Error! - Failure in catch clause - \(error)")
        }
        
        //try? httpClient.syncShutdown()
    }

    private func prettify(_ metadata: Logger.Metadata) -> String? {
        return !metadata.isEmpty
            ? metadata.lazy.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: " ")
            : nil
    }

    private func timestamp() -> String {
        var buffer = [Int8](repeating: 0, count: 255)
        var timestamp = time(nil)
        let localTime = localtime(&timestamp)
        strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S%z", localTime)
        return buffer.withUnsafeBufferPointer {
            $0.withMemoryRebound(to: CChar.self) {
                String(cString: $0.baseAddress!)
            }
        }
    }
    
    private static func unpackMetadata(_ value: Logger.MetadataValue) -> Any {
        /// Based on the core-foundation implementation of `JSONSerialization.isValidObject`, but optimized to reduce the amount of comparisons done per validation.
        /// https://github.com/apple/swift-corelibs-foundation/blob/9e505a94e1749d329563dac6f65a32f38126f9c5/Foundation/JSONSerialization.swift#L52
        func isValidJSONValue(_ value: CustomStringConvertible) -> Bool {
            if value is Int || value is Bool || value is NSNull ||
                (value as? Double)?.isFinite ?? false ||
                (value as? Float)?.isFinite ?? false ||
                (value as? Decimal)?.isFinite ?? false ||
                value is UInt ||
                value is Int8 || value is Int16 || value is Int32 || value is Int64 ||
                value is UInt8 || value is UInt16 || value is UInt32 || value is UInt64 ||
                value is String {
                return true
            }
            
            // Using the official `isValidJSONObject` call for NSNumber since `JSONSerialization.isValidJSONObject` uses internal/private functions to validate them...
            if let number = value as? NSNumber {
                return JSONSerialization.isValidJSONObject([number])
            }
            
            return false
        }
        
        switch value {
        case .string(let value):
            return value
        case .stringConvertible(let value):
            if isValidJSONValue(value) {
                return value
            } else if let date = value as? Date {
                return iso8601DateFormatter.string(from: date)
            } else if let data = value as? Data {
                return data.base64EncodedString()
            } else {
                return value.description
            }
        case .array(let value):
            return value.map { Self.unpackMetadata($0) }
        case .dictionary(let value):
            return value.mapValues { Self.unpackMetadata($0) }
        }
    }
    
    /// ISO 8601 `DateFormatter` which is the accepted format for timestamps in Stackdriver
    private static let iso8601DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()
}

extension LogstashLogHandler {
    public func inject(eventLoopGroup: EventLoopGroup) {
        self.eventLoopGroup?.value = eventLoopGroup
    }
}

extension LogstashLogHandler {
    public func inject(backgroundActivityLogger: Logger) {
        self.backgroundActivityLogger?.value = backgroundActivityLogger
    }
}
