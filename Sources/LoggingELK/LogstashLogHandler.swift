//
//  LogstashLogHandler.swift
//
//
//  Created by Philipp Zagar on 26.06.21.
//

import NIO
import NIOConcurrencyHelpers
import Logging
import AsyncHTTPClient

/// `LogstashLogHandler` is a simple implementation of `LogHandler` for directing
/// `Logger` output to Logstash via HTTP requests
public struct LogstashLogHandler: LogHandler {
    let label: String
    let hostname: String
    let port: Int
    let eventLoopGroup: EventLoopGroup
    let backgroundActivityLogger: Logger
    let uploadInterval: TimeAmount
    let minimumLogStorageSize: Int

    let httpClient: HTTPClient
    @Boxed var httpRequest: HTTPClient.Request?

    @Boxed var byteBuffer: ByteBuffer
    let byteBufferLock = ConditionLock(value: false)
    @Boxed private(set) var uploadTask: RepeatedTask?

    public var logLevel: Logger.Level = .info
    public var metadata = Logger.Metadata()

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    /// Creates a `LogstashLogHandler` that directs its output to Logstash
    /// Make sure that the `backgroundActivityLogger` is instanciated BEFORE `LoggingSystem.bootstrap(...)` is called
    /// Therefore, the `backgroundActivityLogger` uses the default `StreamLogHandler.standardOutput` `LogHandler`
    /// If not, in case of an error occuring error in the logging backend, the `backgroundActivityLogger` will use the `LogstashLogHandler` backend,
    /// resulting in an infinite recursion and to a crash. Sadly, there is no way to check the type of the used backend of the `backgroundActivityLogger` at runtime
    public init(label: String,
                hostname: String = "0.0.0.0",
                port: Int = 31311,
                eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1),
                backgroundActivityLogger: Logger = Logger(label: "backgroundActivity-logstashHandler"),
                uploadInterval: TimeAmount = TimeAmount.seconds(3),
                minimumLogStorageSize: Int = 1_048_576) {
        self.label = label
        self.hostname = hostname
        self.port = port
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(),
            backgroundActivityLogger: backgroundActivityLogger
        )

        self.eventLoopGroup = eventLoopGroup
        self.backgroundActivityLogger = backgroundActivityLogger
        self.uploadInterval = uploadInterval
        self.minimumLogStorageSize = minimumLogStorageSize

        self._byteBuffer = Boxed(wrappedValue: ByteBufferAllocator().buffer(capacity: minimumLogStorageSize))
        self._uploadTask = Boxed(wrappedValue: scheduleUploadTask(initialDelay: uploadInterval))
    }

    public func log(level: Logger.Level,    // swiftlint:disable:this function_parameter_count
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
        let mergedMetadata = mergeMetadata(passedMetadata: metadata, file: file, function: function, line: line)

        guard let logData = encodeLogData(mergedMetadata: mergedMetadata, level: level, message: message) else {
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
        guard self.byteBufferLock.lock(whenValue: false, timeoutSeconds: TimeAmount.seconds(1).rawSeconds) else {
            // If lock couldn't be aquired, don't log the data and just return
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
                        "sizeOfLogStorage": .string("\(self.byteBuffer.capacity)"),
                        "sizeOfLogEntry": .string("\(logData.count)"),
                        "logEntry": .dictionary(
                            [
                                "message": .string(message.description),
                                "metadata": .dictionary(mergedMetadata),
                                "logLevel": .string(level.rawValue)
                            ]
                        )
                    ]
                )
                
                self.byteBufferLock.unlock()
                return
            }
            
            // Cancle the "old" upload task
            self.uploadTask?.cancel(promise: nil)

            // Trigger the upload task immediatly
            self.uploadTask = scheduleUploadTask(initialDelay: TimeAmount.zero)

            // Indicates that the byte buffer is full and must be emptied before writing to it again
            self.byteBufferLock.unlock(withValue: true)
        } else {
            self.byteBufferLock.unlock()
        }

        guard self.byteBufferLock.lock(whenValue: false, timeoutSeconds: TimeAmount.seconds(1).rawSeconds) else {
            // If lock couldn't be aquired, don't log the data and just return
            return
        }

        // Write size of the log data
        self.byteBuffer.writeInteger(logData.count)
        // Write actual log data to log store
        self.byteBuffer.writeData(logData)

        self.byteBufferLock.unlock()
    }
}
