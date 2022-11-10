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
@available(iOS 13.0, *)
public struct LogstashLogHandler: LogHandler {
    /// The label of the `LogHandler`
    let label: String
    /// The host where a Logstash instance is running
    static var hostname: String?
    /// The port of the host where a Logstash instance is running
    static var port: Int?
    /// Specifies if the HTTP connection to Logstash should be encrypted via TLS (so HTTPS instead of HTTP)
    static var useHTTPS: Bool?
    /// Specifies  the authorization schema for the HTTP request
    static var authorization: Authorizable?
    /// The `EventLoopGroup` which is used to create the `HTTPClient`
    static var eventLoopGroup: EventLoopGroup?
    /// Used to log background activity of the `LogstashLogHandler` and `HTTPClient`
    /// This logger MUST be created BEFORE the `LoggingSystem` is bootstrapped, else it results in an infinte recusion!
    static var backgroundActivityLogger: Logger?
    /// Represents a certain amount of time which serves as a delay between the triggering of the uploading to Logstash
    static var uploadInterval: TimeAmount?
    /// Specifies how large the log storage `ByteBuffer` must be at least
    static var logStorageSize: Int?
    /// Specifies how large the log storage `ByteBuffer` with all the current uploading buffers can be at the most
    static var maximumTotalLogStorageSize: Int?

    /// The `HTTPClient` which is used to create the `HTTPClient.Request`
    static var httpClient: HTTPClient?
    /// The `HTTPClient.Request` which stays consistent (except the body) over all uploadings to Logstash
    @Boxed static var httpRequest: HTTPClient.Request?

    /// The log storage byte buffer which serves as a cache of the log data entires
    @Boxed static var byteBuffer: ByteBuffer?
    /// Provides thread-safe access to the log storage byte buffer
    static let byteBufferLock = ConditionLock(value: false)
    
    /// Semaphore to adhere to the maximum memory limit
    static let semaphore = DispatchSemaphore(value: 0)
    /// Manual counter of the semaphore (since no access to the internal one of the semaphore)
    @Boxed static var semaphoreCounter: Int = 0
    /// Keeps track of how much memory is allocated in total
    @Boxed static var totalByteBufferSize: Int?
    
    /// Created during scheduling of the upload function to Logstash, provides the ability to cancel the uploading task
    @Boxed private(set) static var uploadTask: RepeatedTask?

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
    public init(label: String) {
        // If LogstashLogHandler was not yet set up, abort
        guard let _ = Self.hostname else {
            fatalError(Error.notYetSetup.rawValue)
        }
        
        self.label = label
        
        // Set a "super-secret" metadata value to validate that the backgroundActivityLogger
        // doesn't use the LogstashLogHandler as a logging backend
        // Currently, this behavior isn't even possible in production, but maybe in future versions of the swift-log package
        self[metadataKey: "super-secret-is-a-logstash-loghandler"] = .string("true")
    }
    
    /// Setup of the `LogstashLogHandler`, need to be called once before `LoggingSystem.bootstrap(...)` is called
    public static func setup(hostname: String,
                             port: Int,
                             useHTTPS: Bool = false,
                             authorization: Authorizable? = nil,
                             eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: (System.coreCount != 1) ? System.coreCount / 2 : 1),
                             backgroundActivityLogger: Logger = Logger(label: "backgroundActivity-logstashHandler"),
                             uploadInterval: TimeAmount = TimeAmount.seconds(3),
                             logStorageSize: Int = 524_288,
                             maximumTotalLogStorageSize: Int = 4_194_304) {
        // Shutdown httpClient and uploadTask from possible previous setup
        try? Self.httpClient?.syncShutdown()
        Self.uploadTask?.cancel(promise: nil)
        
        Self.hostname = hostname
        Self.port = port
        Self.useHTTPS = useHTTPS
        Self.authorization = authorization
        Self.eventLoopGroup = eventLoopGroup
        Self.backgroundActivityLogger = backgroundActivityLogger
        Self.uploadInterval = uploadInterval
        // If the double minimum log storage size is larger than maximum log storage size throw error
        if maximumTotalLogStorageSize.nextPowerOf2() < (2 * logStorageSize.nextPowerOf2()) {
            fatalError(Error.maximumLogStorageSizeTooLow.rawValue)
        }
        // Round up to the power of two since ByteBuffer automatically allocates in these steps
        Self.logStorageSize = logStorageSize.nextPowerOf2()
        Self.maximumTotalLogStorageSize = maximumTotalLogStorageSize.nextPowerOf2()
        
        Self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(),
            backgroundActivityLogger: backgroundActivityLogger
        )

        // Need to be wrapped in a class since those properties can be mutated
        Self._byteBuffer = Boxed(wrappedValue: ByteBufferAllocator().buffer(capacity: logStorageSize))
        Self._totalByteBufferSize = Boxed(wrappedValue: Self._byteBuffer.wrappedValue?.capacity)
        Self._uploadTask = Boxed(wrappedValue: scheduleUploadTask(initialDelay: uploadInterval))
        
        // Check if backgroundActivityLogger doesn't use the LogstashLogHandler as a logging backend
        if let usesLogstashHandlerValue = backgroundActivityLogger[metadataKey: "super-secret-is-a-logstash-loghandler"],
           case .string(let usesLogstashHandler) = usesLogstashHandlerValue,
           usesLogstashHandler == "true" {
            try? Self.httpClient?.syncShutdown()
            Self.uploadTask?.cancel(promise: nil)
            
            fatalError(Error.backgroundActivityLoggerBackendError.rawValue)
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
        guard let _ = Self.byteBuffer, let uploadInterval = Self.uploadInterval else {
            fatalError(Error.notYetSetup.rawValue)
        }
        
        let mergedMetadata = mergeMetadata(passedMetadata: metadata, file: file, function: function, line: line)

        guard let logData = encodeLogData(level: level, message: message, metadata: mergedMetadata) else {
            Self.backgroundActivityLogger?.log(
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
        guard Self.byteBufferLock.lock(whenValue: false, timeoutSeconds: TimeAmount.seconds(1).rawSeconds) else {
            // If lock couldn't be aquired, don't log the data and just return
            Self.backgroundActivityLogger?.log(
                level: .warning,
                "Lock on the log data byte buffer couldn't be aquired",
                metadata: [
                    "label": .string(self.label),
                    "logStorage": .dictionary(
                        [
                            "readableBytes": .string("\(Self.byteBuffer!.readableBytes)"),
                            "writableBytes": .string("\(Self.byteBuffer!.writableBytes)"),
                            "readerIndex": .string("\(Self.byteBuffer!.readerIndex)"),
                            "writerIndex": .string("\(Self.byteBuffer!.writerIndex)"),
                            "capacity": .string("\(Self.byteBuffer!.capacity)")
                        ]
                    ),
                    "conditionalLockState": .string("\(Self.byteBufferLock.value)")
                ]
            )
            
            return
        }

        // Check if the maximum storage size of the byte buffer would be exeeded.
        // If that's the case, trigger the uploading of the logs manually
        if (Self.byteBuffer!.readableBytes + MemoryLayout<Int>.size + logData.count) > Self.byteBuffer!.capacity {
            // A single log entry is larger than the current byte buffer size
            if Self.byteBuffer?.readableBytes == 0 {
                Self.backgroundActivityLogger?.log(
                    level: .warning,
                    "A single log entry is larger than the configured log storage size",
                    metadata: [
                        "label": .string(self.label),
                        "logStorageSize": .string("\(Self.byteBuffer!.capacity)"),
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
                
                Self.byteBufferLock.unlock()
                return
            }
            
            // Cancle the "old" upload task
            Self.uploadTask?.cancel(promise: nil)
            
            // The state of the lock, in this case "true", indicates, that the byteBuffer
            // is full at the moment and must be emptied before writing to it again
            Self.byteBufferLock.unlock(withValue: true)

            // Trigger the upload task immediatly
            Self.uploadLogData()
            
            // Schedule a new upload task with the appropriate inital delay
            Self.uploadTask = Self.scheduleUploadTask(initialDelay: uploadInterval)
        } else {
            Self.byteBufferLock.unlock()
        }

        guard Self.byteBufferLock.lock(whenValue: false, timeoutSeconds: TimeAmount.seconds(1).rawSeconds) else {
            // If lock couldn't be aquired, don't log the data and just return
            Self.backgroundActivityLogger?.log(
                level: .warning,
                "Lock on the log data byte buffer couldn't be aquired",
                metadata: [
                    "label": .string(self.label),
                    "logStorage": .dictionary(
                        [
                            "readableBytes": .string("\(Self.byteBuffer!.readableBytes)"),
                            "writableBytes": .string("\(Self.byteBuffer!.writableBytes)"),
                            "readerIndex": .string("\(Self.byteBuffer!.readerIndex)"),
                            "writerIndex": .string("\(Self.byteBuffer!.writerIndex)"),
                            "capacity": .string("\(Self.byteBuffer!.capacity)")
                        ]
                    ),
                    "conditionalLockState": .string("\(Self.byteBufferLock.value)")
                ]
            )
            
            return
        }
        
        // Write size of the log data
        Self.byteBuffer?.writeInteger(logData.count)
        // Write actual log data to log store
        Self.byteBuffer?.writeData(logData)

        Self.byteBufferLock.unlock()
    }
}
