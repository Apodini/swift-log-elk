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
    private var httpClient: HTTPClient
    private var eventLoopGroup: EventLoopGroup
    private var backgroundActivityLogger: Logger
    //private var timer: Box<Publishers.Autoconnect<Timer.TimerPublisher>?>? = Box(nil)
    
//    private static var uploadInverval: TimeInterval = 10 {
//        willSet {
//            timer.schedule(deadline: DispatchTime.now(), repeating: newValue)
//
//            //self.backgroundActivityLogger?.value?.debug("Log upload interval has been updated", metadata: ["uploadInterval": .string(String(describing: newValue))])
//        }
//    }
//
//    private static let timer: DispatchSourceTimer = {
//        let timer = DispatchSource.makeTimerSource()
//        timer.setEventHandler(handler: uploadOnSchedule)
//        if #available(macOS 10.12, *) {
//            timer.activate()
//        } else {
//            timer.resume()
//        }
//        return timer
//    }()
//
//    private static let networkHandleQueue = DispatchQueue(label: "LogstashLogHandler.NetworkHandle")
//
//    private func setup() {
//        DispatchQueue.main.async { // Async in case setup before LoggingSystem bootstrap.
//            self.backgroundActivityLogger?.value?.info("LogstashLogHandler has been setup", metadata: [:])
//        }
//    }
//
//    private static func upload() {
//
//        //assert(logging != nil, "App must setup GoogleCloudLogHandler before upload")
//
//        timer.schedule(deadline: DispatchTime.now(), repeating: uploadInterval)
//    }
//
//    private static func uploadOnSchedule() {
//
//    }
    //rivate let test = Timer.publish(every: 5, tolerance: 1, on: .main, in: .common).autoconnect().sink { _ in print("test") }
    
//    private let publisher: Box<Timer.OCombine.TimerPublisher?>? = Box(nil)
//    private let anyCancellables: Box<OpenCombine.AnyCancellable?>? = Box(nil)
//
//    // No idea why this doesn't work
//    private func setup() {
//        publisher?.value = Timer.publish(every: 5, tolerance: 1, on: .main, in: .common)
//
//        anyCancellables?.value = publisher?.value?.autoconnect().sink{ _ in
//            print("asdf")
//        }
//    }
    
    /*
    private let test = Timer   //Timer.publish(every: 5, tolerance: 1, on: .current, in: .common).autoconnect()
    private var anyCanc = Set<AnyCancellable>()
    private func setup() {
        test.sink { _ in
            print("test")
        }
        .store(in: &anyCanc)
    }
     */

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

    internal init(label: String,
                  hostname: String,
                  port: Int,
                  eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1),
                  backgroundActivityLogger: Logger = Logger(label: "BackgroundActivityLogstashHandler")) {
        self.label = label
        self.hostname = hostname
        self.port = port
        self.eventLoopGroup = eventLoopGroup
        self.backgroundActivityLogger = backgroundActivityLogger
        
        //setup()
        
        // Initialze HHTP Client
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(),
            backgroundActivityLogger: backgroundActivityLogger
        )
    }
    
    /// Factory that makes a `LogstashLogHandler` to directs its output to Logstash
    public static func logstashOutput(label: String,
                                      hostname: String = "127.0.0.1",
                                      port: Int = 31311,
                                      eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1),
                                      backgroundActivityLogger: Logger = Logger(label: "BackgroundActivityLogstashHandler")) -> LogstashLogHandler {
        return LogstashLogHandler(label: label, hostname: hostname, port: port, eventLoopGroup: eventLoopGroup, backgroundActivityLogger: backgroundActivityLogger)
    }

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
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
            let bodyJSON = try JSONEncoder().encode(bodyObject)
            request.body = .data(bodyJSON)
            
            /// Execute request
            httpClient.execute(request: request).whenComplete { result in
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
        } catch {
            self.backgroundActivityLogger.log(level: .warning,
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

