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
    /// The label of the `LogHandler`
    let label: String
    /// The host where a Logstash instance is running
    let hostname: String
    /// The port of the host where a Logstash instance is running
    let port: Int
    /// Specifies if the HTTP connection to Logstash should be encrypted via TLS (so HTTPS instead of HTTP)
    let useHTTPS: Bool
    /// The `EventLoopGroup` which is used to create the `HTTPClient`
    let eventLoopGroup: EventLoopGroup
    /// Used to log background activity of the `LogstashLogHandler` and `HTTPClient`
    /// This logger MUST be created BEFORE the `LoggingSystem` is bootstrapped, else it results in an infinte recusion!
    let backgroundActivityLogger: Logger
    /// Represents a certain amount of time which serves as a delay between the triggering of the uploading to Logstash
    let uploadInterval: TimeAmount
    /// Specifies how large the log storage `ByteBuffer` must be at least
    let logStorageSize: Int
    /// Specifies how large the log storage `ByteBuffer` with all the current uploading buffers can be at the most
    let maximumTotalLogStorageSize: Int

    /// The `HTTPClient` which is used to create the `HTTPClient.Request`
    let httpClient: HTTPClient
    /// The `HTTPClient.Request` which stays consistent (except the body) over all uploadings to Logstash
    @Boxed var httpRequest: HTTPClient.Request?

    /// The log storage byte buffer which serves as a cache of the log data entires
    @Boxed var byteBuffer: ByteBuffer
    /// Provides thread-safe access to the log storage byte buffer
    let byteBufferLock = ConditionLock(value: false)
    
    /// Keeps track of how much memory is allocated in total
    @Boxed var totalByteBufferSize: Int
    /// Semaphore to adhere to the maximum memory limit
    let semaphore = DispatchSemaphore(value: 0)
    /// Manual counter of the semaphore (since no access to the internal one of the semaphore)
    @Boxed var semaphoreCounter: Int = 0
    /// Created during scheduling of the upload function to Logstash, provides the ability to cancle the uploading task
    @Boxed private(set) var uploadTask: RepeatedTask?

    /// The default `Logger.Level` of the `LogstashLogHandler`
    /// Logging entries below this `Logger.Level` won't get logged at all
    public var logLevel: Logger.Level = .info
    /// Holds the `Logger.Metadata` of the `LogstashLogHandler`
    public var metadata = Logger.Metadata()
    /// Convenience subscript to get and set `Logger.Metadata`
    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    /// Creates a `LogstashLogHandler` that directs its output to Logstash
    // Make sure that the `backgroundActivityLogger` is instanciated BEFORE `LoggingSystem.bootstrap(...)` is called (currently not even possible otherwise)
    public init(label: String,
                hostname: String = "0.0.0.0",
                port: Int = 31311,
                useHTTPS: Bool = false,
                eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: (System.coreCount != 1) ? System.coreCount / 2 : 1),
                backgroundActivityLogger: Logger = Logger(label: "backgroundActivity-logstashHandler"),
                uploadInterval: TimeAmount = TimeAmount.seconds(3),
                logStorageSize: Int = 524_288,
                maximumTotalLogStorageSize: Int = 4_194_304) throws {
        self.label = label
        self.hostname = hostname
        self.port = port
        self.useHTTPS = useHTTPS
        self.eventLoopGroup = eventLoopGroup
        self.backgroundActivityLogger = backgroundActivityLogger
        self.uploadInterval = uploadInterval
        // Round up to the power of two since ByteBuffer automatically allocates in these steps
        self.logStorageSize = logStorageSize.nextPowerOf2()
        self.maximumTotalLogStorageSize = maximumTotalLogStorageSize.nextPowerOf2()
        
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(),
            backgroundActivityLogger: backgroundActivityLogger
        )

        // Need to be wrapped in a class since those properties can be mutated
        self._byteBuffer = Boxed(wrappedValue: ByteBufferAllocator().buffer(capacity: logStorageSize))
        self._totalByteBufferSize = Boxed(wrappedValue: self._byteBuffer.wrappedValue.capacity)
        self._uploadTask = Boxed(wrappedValue: scheduleUploadTask(initialDelay: uploadInterval))
        
        // Doesn't work properly
//        defer {
//            try? self.httpClient.syncShutdown()
//            self.uploadTask?.cancel(promise: nil)
//        }
        
        // If the double minimum log storage size is larger than maximum log storage size throw error
        if self.maximumTotalLogStorageSize < (2 * self.logStorageSize) {
            try? self.httpClient.syncShutdown()
            self.uploadTask?.cancel(promise: nil)
            
            throw Error.maximumLogStorageSizeTooLow
        }
        
        // Set a "super-secret" metadata value to validate that the backgroundActivityLogger
        // doesn't use the LogstashLogHandler as a logging backend
        // Currently, this behavior isn't even possible, but maybe in future versions of the swift-log package
        self[metadataKey: "super-secret-is-a-logstash-loghandler"] = .string("true")
        
        // Check if backgroundActivityLogger doesn't use the LogstashLogHandler as a logging backend
        if let usesLogstashHandlerValue = backgroundActivityLogger[metadataKey: "super-secret-is-a-logstash-loghandler"],
           case .string(let usesLogstashHandler) = usesLogstashHandlerValue,
           usesLogstashHandler == "true" {
            try? self.httpClient.syncShutdown()
            self.uploadTask?.cancel(promise: nil)
            
            throw Error.backgroundActivityLoggerBackendError
        }
    }

    /// The main log function of the `LogstashLogHandler`
    /// Merges the `Logger.Metadata`, encodes the log entry to a propertly formatted HTTP body
    /// which is then cached in the log store `ByteBuffer`
    // This function is thread-safe via a `ConditionalLock` on the log store `ByteBuffer`
    public func log(level: Logger.Level,            // swiftlint:disable:this function_parameter_count function_body_length
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
        let mergedMetadata = mergeMetadata(passedMetadata: metadata, file: file, function: function, line: line)

        guard let logData = encodeLogData(level: level, message: message, metadata: mergedMetadata) else {
            self.backgroundActivityLogger.log(
                level: .warning,
                "Error during encoding log data",
                metadata: [
                    "label": .string(self.label),
                    "logEntry": .dictionary(
                        [
                            "message": .string(message.description),
                            "metadata": .dictionary(mergedMetadata),
                            "logLevel": .string(level.rawValue)
                        ]
                    )
                ]
            )

            return
        }
        
        // The conditional lock ensures that the uploading function is not "manually" scheduled multiple times
        // The state of the lock, in this case "false", indicates, that the byteBuffer isn't full at the moment
        guard self.byteBufferLock.lock(whenValue: false, timeoutSeconds: TimeAmount.seconds(1).rawSeconds) else {
            // If lock couldn't be aquired, don't log the data and just return
            self.backgroundActivityLogger.log(
                level: .warning,
                "Lock on the log data byte buffer couldn't be aquired",
                metadata: [
                    "label": .string(self.label),
                    "logStorage": .dictionary(
                        [
                            "readableBytes": .string("\(self.byteBuffer.readableBytes)"),
                            "writableBytes": .string("\(self.byteBuffer.writableBytes)"),
                            "readerIndex": .string("\(self.byteBuffer.readerIndex)"),
                            "writerIndex": .string("\(self.byteBuffer.writerIndex)"),
                            "capacity": .string("\(self.byteBuffer.capacity)")
                        ]
                    ),
                    "conditionalLockState": .string("\(self.byteBufferLock.value)")
                ]
            )
            
            return
        }

        // Check if the maximum storage size of the byte buffer would be exeeded.
        // If that's the case, trigger the uploading of the logs manually
        if (self.byteBuffer.readableBytes + MemoryLayout<Int>.size + logData.count) > self.byteBuffer.capacity {
            // A single log entry is larger than the current byte buffer size
            if self.byteBuffer.readableBytes == 0 {
                self.backgroundActivityLogger.log(
                    level: .warning,
                    "A single log entry is larger than the configured log storage size",
                    metadata: [
                        "label": .string(self.label),
                        "logStorageSize": .string("\(self.byteBuffer.capacity)"),
                        "logEntry": .dictionary(
                            [
                                "message": .string(message.description),
                                "metadata": .dictionary(mergedMetadata),
                                "logLevel": .string(level.rawValue),
                                "size": .string("\(logData.count)")
                            ]
                        )
                    ]
                )
                
                self.byteBufferLock.unlock()
                return
            }
            
            // Cancle the "old" upload task
            self.uploadTask?.cancel(promise: nil)
            
            // The state of the lock, in this case "true", indicates, that the byteBuffer
            // is full at the moment and must be emptied before writing to it again
            self.byteBufferLock.unlock(withValue: true)

            // Trigger the upload task immediatly
            uploadLogData()
            
            // Schedule a new upload task with the appropriate inital delay
            self.uploadTask = scheduleUploadTask(initialDelay: self.uploadInterval)
        } else {
            self.byteBufferLock.unlock()
        }

        guard self.byteBufferLock.lock(whenValue: false, timeoutSeconds: TimeAmount.seconds(1).rawSeconds) else {
            // If lock couldn't be aquired, don't log the data and just return
            self.backgroundActivityLogger.log(
                level: .warning,
                "Lock on the log data byte buffer couldn't be aquired",
                metadata: [
                    "label": .string(self.label),
                    "logStorage": .dictionary(
                        [
                            "readableBytes": .string("\(self.byteBuffer.readableBytes)"),
                            "writableBytes": .string("\(self.byteBuffer.writableBytes)"),
                            "readerIndex": .string("\(self.byteBuffer.readerIndex)"),
                            "writerIndex": .string("\(self.byteBuffer.writerIndex)"),
                            "capacity": .string("\(self.byteBuffer.capacity)")
                        ]
                    ),
                    "conditionalLockState": .string("\(self.byteBufferLock.value)")
                ]
            )
            
            return
        }
        
        // Write size of the log data
        self.byteBuffer.writeInteger(logData.count)
        // Write actual log data to log store
        self.byteBuffer.writeData(logData)

        self.byteBufferLock.unlock()
    }
}
