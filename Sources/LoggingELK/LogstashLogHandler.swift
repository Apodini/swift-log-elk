//
//  LogstashLogHandler.swift
//
//
//  Created by Philipp Zagar on 26.06.21.
//

import Foundation
import NIO
import NIOConcurrencyHelpers
import Logging
import AsyncHTTPClient

/// `LogstashLogHandler` is a simple implementation of `LogHandler` for directing
/// `Logger` output to Logstash via HTTP requests
public struct LogstashLogHandler: LogHandler {
    private let label: String
    private let hostname: String
    private let port: Int
    private let httpClient: HTTPClient
    private var httpRequest: Box<HTTPClient.Request?> = Box(nil)
    private let eventLoopGroup: EventLoopGroup
    private let backgroundActivityLogger: Logger
    private let uploadInterval: TimeAmount
    
    private let maximumLogStorageSize: Int
    private var currentLogStorageSize: Box<Int> = Box(0)
    private let storageSizeLock = Lock()
    
    private var logs: Box<Set<Data>> = Box(Set<Data>())
    private let lock = Lock()

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

    /// Creates a `LogstashLogHandler` to directs its output to Logstash
    public init(label: String,
                hostname: String = "0.0.0.0",
                port: Int = 31311,
                eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1),
                backgroundActivityLogger: Logger = Logger(label: "BackgroundActivityLogstashHandler"),
                uploadInterval: TimeAmount = TimeAmount.seconds(10),
                maximumLogStorageSize: Int = 1048576) {
        self.label = label
        self.hostname = hostname
        self.port = port
        self.eventLoopGroup = eventLoopGroup
        self.backgroundActivityLogger = backgroundActivityLogger
        self.uploadInterval = uploadInterval
        self.maximumLogStorageSize = maximumLogStorageSize
        
        /// Initialze HHTP Client
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(),
            backgroundActivityLogger: backgroundActivityLogger
        )
        
        do {
            /// Create the base HTTP Request
            self.httpRequest.value = try HTTPClient.Request(url: "http://\(hostname):\(port)", method: .POST)
        } catch {
            fatalError("Logstash HTTP Request couldn't be created. Check if the hostname and port are valid. \(error)")
        }
        
        /// Set headers that always stay consistent over all requests
        self.httpRequest.value?.headers.add(name: "Content-Type", value: "application/json")
        self.httpRequest.value?.headers.add(name: "Accept", value: "application/json")
        /// Keep-alive header to keep the connection open
        self.httpRequest.value?.headers.add(name: "Connection", value: "keep-alive")
        self.httpRequest.value?.headers.add(name: "Keep-Alive", value: "timeout=30, max=120")
        
        /// Setup of the repetitive uploading of the logs to Logstash
        self.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: uploadInterval, delay: uploadInterval, notifying: nil, upload)
    }
    
    private func upload(_ task: RepeatedTask? = nil) throws -> Void {
        /// Log set empty
        guard !self.logs.value.isEmpty else {
            return
        }
        
        /// Extract values out of log set and remove the values from the original set
        var copyLogs = Set<Data>()
        lock.withLock {
            /// Extract values
            copyLogs.formUnion(self.logs.value)
            /// Remove original values on the log set of the struct
            self.logs.value.removeAll()
            
            /// Reset current size of log storage set
            self.storageSizeLock.withLock {
                self.currentLogStorageSize.value = 0
            }
        }
        
        copyLogs.forEach { logData in
            /// HTTP Request not initialized
            guard var httpRequest = self.httpRequest.value else {
                return
            }
            
            /// Set the saved logdata to the body of the request
            httpRequest.body = .data(logData)
            
            /// Execute HTTP request
            self.httpClient.execute(request: httpRequest).whenComplete { result in
                switch result {
                case .failure(let error):
                    self.backgroundActivityLogger.log(level: .warning,
                                                      "Error during sending logs to Logstash - \(error)",
                                                      metadata: ["hostname":.string(self.hostname),
                                                                 "port":.string(String(describing: self.port)),
                                                                 "label":.string(self.label)])
                case .success(let response):
                    if response.status == .ok {
                        print("Success!")  /// TODO: Remove that when development is finished
                    } else {
                        self.backgroundActivityLogger.log(level: .warning,
                                                          "Error during sending logs to Logstash - \(String(describing: response.status))",
                                                          metadata: ["hostname":.string(self.hostname),
                                                                     "port":.string(String(describing: self.port)),
                                                                     "label":.string(self.label)])
                    }
                }
            }
        }
    }

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
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
        /// The completly encoded data
        var logData: Data
        
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
            logData = try JSONEncoder().encode(bodyObject)
            
            /// Increment current size of log storage set
            self.storageSizeLock.withLock {
                self.currentLogStorageSize.value += logData.count
            }
        } catch {
            self.backgroundActivityLogger.log(level: .warning,
                                              "Error during encoding log data - \(error))",
                                              metadata: ["hostname":.string(self.hostname),
                                                         "port":.string(String(describing: self.port)),
                                                         "label":.string(self.label)])
            return
        }
            
        self.lock.withLock {
            /// Save finished body to the log set
            self.logs.value.insert(logData)
            
            /// To silence "return value unused" warning
            return
        }

        /// Check if the maximum storage size is exeeded, then upload the logs manually
        if self.currentLogStorageSize.value > self.maximumLogStorageSize {
            do {
                try upload()
            } catch {
                self.backgroundActivityLogger.log(level: .warning,
                                                  "Error uploading logs if memory limit is exeeded",
                                                  metadata: ["hostname":.string(self.hostname),
                                                             "port":.string(String(describing: self.port)),
                                                             "label":.string(self.label)])
            }
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

