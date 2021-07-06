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
public struct LogstashLogHandler: LogHandler {
    private let label: String
    private let hostname: String
    private let port: Int
    private var httpClient: Box<HTTPClient?>? = Box(nil)
    private var eventLoopGroup: Box<EventLoopGroup?>? = Box(nil)
    private var backgroundActivityLogger: Box<Logger?>? = Box(nil)

    /// Not sure for what exactly this is necessary, but its mandated by the `LogHandler` protocol
    public var logLevel: Logger.Level = .info
    
    public var metadata = Logger.Metadata()

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            return self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    internal init(label: String, hostname: String, port: Int, eventLoopGroup: EventLoopGroup? = nil, backgroundActivityLogger: Logger? = nil) {
        self.label = label
        self.hostname = hostname
        self.port = port
        self.eventLoopGroup?.value = eventLoopGroup
        self.backgroundActivityLogger?.value = backgroundActivityLogger
        
        // Initialze HHTP Client - ugly since there are 4 possibilities
        if let eventLoopGroup = eventLoopGroup {
            if let backgroundActivityLogger = backgroundActivityLogger {
                // Existing eventloop, existing logger
                self.httpClient?.value = HTTPClient(
                    eventLoopGroupProvider: .shared(eventLoopGroup),
                    configuration: HTTPClient.Configuration(),
                    backgroundActivityLogger: backgroundActivityLogger
                )
            } else {
                // Existing eventloop, no logger
                self.httpClient?.value = HTTPClient(
                    eventLoopGroupProvider: .shared(eventLoopGroup),
                    configuration: HTTPClient.Configuration()
                )
            }
        } else {
            if let backgroundActivityLogger = backgroundActivityLogger {
                // No eventloop, exisiting logger
                self.httpClient?.value = HTTPClient(
                    eventLoopGroupProvider: .createNew,
                    configuration: HTTPClient.Configuration(),
                    backgroundActivityLogger: backgroundActivityLogger
                )
            } else {
                // No eventloop, no logger
                self.httpClient?.value = HTTPClient(
                    eventLoopGroupProvider: .createNew,
                    configuration: HTTPClient.Configuration()
                )
            }
        }
    }
    
    /// Factory that makes a `LogstashLogHandler` to directs its output to Logstash
    public static func logstashOutput(label: String, hostname: String = "127.0.0.1", port: Int = 31311, eventLoopGroup: EventLoopGroup? = nil, backgroundActivityLogger: Logger? = nil) -> LogstashLogHandler {
        return LogstashLogHandler(label: label, hostname: hostname, port: port, eventLoopGroup: eventLoopGroup, backgroundActivityLogger: backgroundActivityLogger)
    }

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
        guard let httpClient = self.httpClient?.value else {
            fatalError("HTTPClient not initialized!")
        }
        
        do {
            /// Create the base HTTP Request
            var request = try HTTPClient.Request(url: "http://\(hostname):\(port)", method: .POST)
            request.headers.add(name: "Content-Type", value: "application/json")
            request.headers.add(name: "Accept", value: "application/json")
            // Maybe also a keep-alive header to keep the connection open
            request.headers.add(name: "Connection", value: "keep-alive")
            request.headers.add(name: "Keep-Alive", value: "timeout=300, max=1000")
            
            /// Merge the metadata
            let entryMetadata: Logger.Metadata
            if let parameterMetadata = metadata {
                entryMetadata = self.metadata.merging(parameterMetadata) { $1 }
                                             .merging(["location":.string(formatLocation(file: file, function: function, line: line))]) { $1 }
            } else {
                entryMetadata = self.metadata.merging(["location":.string(formatLocation(file: file, function: function, line: line))]) { $1 }
            }
            
            /// Unpack the metadata values to a normal dictionary
            let unpackedMetadata = Self.unpackMetadata(.dictionary(entryMetadata)) as! [String: Any]
            
            /// Encode the metadata to JSON again
            let encodedMetadata: Data
            if #available(macOS 10.15, *) {
                encodedMetadata = try JSONSerialization.data(withJSONObject: unpackedMetadata, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            } else if #available(macOS 10.13, *) {
                encodedMetadata = try JSONSerialization.data(withJSONObject: unpackedMetadata, options: [.prettyPrinted, .sortedKeys])
                self.backgroundActivityLogger?.value?.log(level: .warning,
                                                          "Metadata couldn't be encoded properly since macOS version is too low!",
                                                          metadata: ["hostname":.string(self.hostname),
                                                                     "port":.string(String(describing: self.port)),
                                                                     "label":.string(self.label)])
            } else {
                encodedMetadata = try JSONSerialization.data(withJSONObject: unpackedMetadata, options: [.prettyPrinted])
                self.backgroundActivityLogger?.value?.log(level: .warning,
                                                          "Metadata couldn't be encoded properly since macOS version is too low!",
                                                          metadata: ["hostname":.string(self.hostname),
                                                                     "port":.string(String(describing: self.port)),
                                                                     "label":.string(self.label)])
            }
            
            /// JSON to String
            let stringyfiedMetadata = String(decoding: encodedMetadata, as: UTF8.self)
            //print(stringyfiedMetadata)
            
            /// Create HTTP Request body
            let bodyObject = LogstashHTTPBody(timestamp: timestamp(),
                                              loglevel: level,
                                              message: message.description,
                                              metadata: stringyfiedMetadata)
            
            /// Encode body
            let bodyJSON = try JSONEncoder().encode(bodyObject)
            request.body = .data(bodyJSON)
            
            /// Execute request
            httpClient.execute(request: request).whenComplete { result in
                switch result {
                case .failure(let error):
                    self.backgroundActivityLogger?.value?.log(level: .warning,
                                                              "Error during sending logs to Logstash - \(error)",
                                                              metadata: ["hostname":.string(self.hostname),
                                                                         "port":.string(String(describing: self.port)),
                                                                         "label":.string(self.label)])
                case .success(let response):
                    if response.status == .ok {
                        print("Success!")  /// TODO: Remove that when development is finished
                    } else {
                        self.backgroundActivityLogger?.value?.log(level: .warning,
                                                                  "Error during sending logs to Logstash - \(String(describing: response.status))",
                                                                  metadata: ["hostname":.string(self.hostname),
                                                                             "port":.string(String(describing: self.port)),
                                                                             "label":.string(self.label)])
                    }
                }
            }
        } catch {
            self.backgroundActivityLogger?.value?.log(level: .warning,
                                                      "Error during sending logs to Logstash - \(error))",
                                                      metadata: ["hostname":.string(self.hostname),
                                                                 "port":.string(String(describing: self.port)),
                                                                 "label":.string(self.label)])
        }
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
}

extension LogstashLogHandler {
    private struct LogstashHTTPBody: Encodable {
        let timestamp: String
        let loglevel: Logger.Level
        let message: String
        let metadata: String
    }
    
    private func conciseSourcePath(_ path: String) -> String {
        return path.split(separator: "/")
            .split(separator: "Sources")
            .last?
            .joined(separator: "/") ?? path
    }
    
    private func formatLocation(file: String, function: String, line: UInt) -> String {
        "\(self.conciseSourcePath(file)) ▶ \(function) ▶ \(line)"
    }
}

extension LogstashLogHandler: EventLoopGroupInjectable {
    public func inject(eventLoopGroup: EventLoopGroup) {
        self.eventLoopGroup?.value = eventLoopGroup
        
        /// If HTTPClient already exists, shut it down gracefully
        if let httpClient = self.httpClient?.value {
            do {
                try httpClient.syncShutdown()
            } catch {
                print("Error during HTTPClient shutdown")
            }
        }
        
        if let backgroundActivityLogger = self.backgroundActivityLogger?.value {
            // Existing eventloop, existing logger
            self.httpClient?.value = HTTPClient(
                eventLoopGroupProvider: .shared(eventLoopGroup),
                configuration: HTTPClient.Configuration(),
                backgroundActivityLogger: backgroundActivityLogger
            )
        } else {
            // Existing eventloop, no logger
            self.httpClient?.value = HTTPClient(
                eventLoopGroupProvider: .shared(eventLoopGroup),
                configuration: HTTPClient.Configuration()
            )
        }
    }
}

extension LogstashLogHandler: BackgroundActivityLoggerInjectable {
    public func inject(backgroundActivityLogger: Logger) {
        self.backgroundActivityLogger?.value = backgroundActivityLogger
        
        /// If HTTPClient already exists, shut it down gracefully
        if let httpClient = self.httpClient?.value {
            do {
                try httpClient.syncShutdown()
            } catch {
                print("Error during HTTPClient shutdown")
            }
        }
        
        if let eventLoopGroup = self.eventLoopGroup?.value {
            // Existing eventloop, existing logger
            self.httpClient?.value = HTTPClient(
                eventLoopGroupProvider: .shared(eventLoopGroup),
                configuration: HTTPClient.Configuration(),
                backgroundActivityLogger: backgroundActivityLogger
            )
        } else {
            // No eventloop, exisiting logger
            self.httpClient?.value = HTTPClient(
                eventLoopGroupProvider: .createNew,
                configuration: HTTPClient.Configuration(),
                backgroundActivityLogger: backgroundActivityLogger
            )
        }
    }
}
