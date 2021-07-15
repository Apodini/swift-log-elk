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
    internal let label: String
    internal let hostname: String
    internal let port: Int
    
    internal let httpClient: HTTPClient
    @Boxed internal var httpRequest: HTTPClient.Request? = nil
    
    internal let eventLoopGroup: EventLoopGroup
    internal let backgroundActivityLogger: Logger
    internal let uploadInterval: TimeAmount
    internal let minimumLogStorageSize: Int
    
    @Boxed internal var byteBuffer: ByteBuffer = ByteBuffer()
    
    /// Lock for writing/reading to/from the byteBuffer
    internal let lock = ConditionLock(value: false)
    
    /// Make optional, then write nil to it
    //@Boxed internal var repeatedTask: RepeatedTask

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
                minimumLogStorageSize: Int = 1048576) {
        self.label = label
        self.hostname = hostname
        self.port = port
        self.eventLoopGroup = eventLoopGroup
        self.backgroundActivityLogger = backgroundActivityLogger
        self.uploadInterval = uploadInterval
        self.minimumLogStorageSize = minimumLogStorageSize
        
        /// Initialize HTTP Client
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: HTTPClient.Configuration(),
            backgroundActivityLogger: backgroundActivityLogger
        )
        
        /// Initialize ByteBuffer to store logs
        self.byteBuffer = ByteBufferAllocator().buffer(capacity: minimumLogStorageSize)
        /// Gets automatically substituted to something like that
        //self._byteBuffer = Boxed(wrappedValue: allocator.buffer(capacity: self.maximumLogStorageSize))
        //self._byteBuffer.wrappedValue = allocator.buffer(capacity: self.maximumLogStorageSize)
        
        /// Prepare the HTTP Request
        self.httpRequest = createHTTPRequest()
        
        /// Setup of the repetitive uploading of the logs to Logstash
        // If the return type here can be cancled, then cancle the scheduled eventloop and send the
        // RepeatedTask offers a cancable method
        let _ = scheduleUploadTask(initialDelay: uploadInterval)
        //self.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: uploadInterval, delay: uploadInterval, notifying: nil, upload)
        //self.repeatedTask = self.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: uploadInterval, delay: uploadInterval, notifying: nil, upload)
        //self._repeatedTask = Boxed(wrappedValue: self.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: uploadInterval, delay: uploadInterval, notifying: nil, upload))
        //self._repeatedTask.wrappedValue = self.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: uploadInterval, delay: uploadInterval, notifying: nil, upload)
    }

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
        /// Merge metadata
        let mergedMetadata = mergeMetadata(passedMetadata: metadata, file: file, function: function, line: line)
        
        /// Encode the logdata
        guard let logData = encodeLogData(mergedMetadata: mergedMetadata, level: level, message: message) else {
            self.backgroundActivityLogger.log(level: .warning,
                                              "Error during encoding log data",
                                              metadata: ["hostname":.string(self.hostname),
                                                         "port":.string(String(describing: self.port)),
                                                         "label":.string(self.label)])
            
            return
        }
        
        /// Lock only if state value is "false", indicating that no operations on the temp byte buffer during uploading are taking place
        /// Helps to prevent a second logging during the time it takes for the upload task to be executed -> Therefore ensures that we don't schedule the upload task twice
        guard self.lock.lock(whenValue: false, timeoutSeconds: 1) else {
            /// If lock couldn't be aquired, don't log the data and just return
            return
        }
        
        /// Check if the maximum storage size would be exeeded. If that's the case, trigger the uploading of the logs manually
        if (self.byteBuffer.readableBytes + MemoryLayout<Int>.size + logData.count) > self.byteBuffer.capacity {
            // TODO: cancle the old repeating upload task
            
            /// Trigger the upload task immediatly
            let _ = scheduleUploadTask(initialDelay: TimeAmount.zero)
            
            /// Unlock with state value "true", indicating that the copying into a temp byte buffer during uploading takes place now
            self.lock.unlock(withValue: true)
        } else {
            /// Unlock regardless of the current state value
            self.lock.unlock()
        }
        
        /// Lock only if state value is "false", indicating that no operations on the temp byte buffer during uploading are taking place
        guard self.lock.lock(whenValue: false, timeoutSeconds: 1) else {
            /// If lock couldn't be aquired, don't log the data and just return
            return
        }
        
        /// Write size of the log data
        self.byteBuffer.writeInteger(logData.count)
        /// Write actual log data to log store
        self.byteBuffer.writeData(logData)
        
        /// Unlock regardless of the current state value
        self.lock.unlock()
    }
}
