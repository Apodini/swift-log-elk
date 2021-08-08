//
//  LogstashLogHandler+Uploading.swift
//  
//
//  Created by Philipp Zagar on 15.07.21.
//

import NIO
import NIOConcurrencyHelpers
import AsyncHTTPClient

extension LogstashLogHandler {
    /// Schedules the `uploadLogData` function with a certain `TimeAmount` as `initialDelay` and `delay` (delay between repeating the task)
    static func scheduleUploadTask(initialDelay: TimeAmount) -> RepeatedTask {
        guard let eventLoopGroup = Self.eventLoopGroup,
              let uploadInterval = Self.uploadInterval else {
                  fatalError(Error.notYetSetup.rawValue)
              }
        
        return eventLoopGroup
            .next()
            .scheduleRepeatedTask(
                initialDelay: initialDelay,
                delay: uploadInterval,
                notifying: nil,
                uploadLogData
            )
    }
    
    /// Function which uploads the stored log data in the `ByteBuffer` to Logstash
    /// Never called directly, its only scheduled via the `scheduleUploadTask` function
    /// This function is thread-safe and designed to only block the stored log data `ByteBuffer`
    /// for a short amount of time (the time it takes to duplicate this bytebuffer). Then, the "original"
    /// stored log data `ByteBuffer` is freed and the lock is lifted
    static func uploadLogData(_ task: RepeatedTask? = nil) {       // swiftlint:disable:this cyclomatic_complexity function_body_length
        guard let _ = Self.byteBuffer,
              let _ = Self.totalByteBufferSize,
              let maximumTotalLogStorageSize = Self.maximumTotalLogStorageSize,
              let eventLoopGroup = Self.eventLoopGroup,
              let httpClient = Self.httpClient,
              let hostname = Self.hostname,
              let port = Self.port else {
            fatalError(Error.notYetSetup.rawValue)
        }
        
        guard Self.byteBuffer?.readableBytes != 0 else {
            return
        }
        
        // If total byte buffer size is exceeded, wait until the size is decreased again
        if totalByteBufferSize! + Self.byteBuffer!.capacity > maximumTotalLogStorageSize {
            Self.semaphoreCounter -= 1
            Self.semaphore.wait()
        }
        
        Self.byteBufferLock.lock()
        
        totalByteBufferSize! += Self.byteBuffer!.capacity
        
        // Copy log data into a temporary byte buffer
        // This helps to prevent a stalling request if more than the max. buffer size
        // log messages are created during uploading of the "old" log data
        var tempByteBuffer = ByteBufferAllocator().buffer(capacity: Self.byteBuffer!.readableBytes)
        tempByteBuffer.writeBuffer(&Self.byteBuffer!)
        
        Self.byteBuffer?.clear()
        
        Self.byteBufferLock.unlock(withValue: false)
        
        // Setup of HTTP requests that is used for all transmissions
        if Self.httpRequest == nil {
            Self.httpRequest = Self.createHTTPRequest()
        }
        
        var pendingHTTPRequests: [EventLoopFuture<HTTPClient.Response>] = []
        
        // Read data from temp byte buffer until it doesn't contain any readable bytes anymore
        while tempByteBuffer.readableBytes != 0 {
            guard let logDataSize: Int = tempByteBuffer.readInteger(),
                  let logData = tempByteBuffer.readSlice(length: logDataSize) else {
                      fatalError("Error reading log data from byte buffer")
                  }
            
            guard var httpRequest = Self.httpRequest else {
                fatalError("HTTP Request not properly initialized")
            }
            
            httpRequest.body = .byteBuffer(logData)
            
            pendingHTTPRequests.append(
                httpClient.execute(request: httpRequest)
            )
        }
        
        // Wait until all HTTP requests finished, then signal waiting threads
        _ = EventLoopFuture<HTTPClient.Response>
            .whenAllComplete(pendingHTTPRequests, on: eventLoopGroup.next())
            .map { results in
                _ = results.map { result in
                    switch result {
                    case .failure(let error):
                        Self.backgroundActivityLogger?.log(
                            level: .warning,
                            "Error during sending logs to Logstash - \(error)",
                            metadata: [
                                "hostname": .string(hostname),
                                "port": .string("\(port)")
                            ]
                        )
                    case .success(let response):
                        if response.status != .ok {
                            Self.backgroundActivityLogger?.log(
                                level: .warning,
                                "Error during sending logs to Logstash - \(String(describing: response.status))",
                                metadata: [
                                    "hostname": .string(hostname),
                                    "port": .string("\(port)")
                                ]
                            )
                        }
                    }
                }
                
                Self.byteBufferLock.lock()
                
                // Once all HTTP requests are completed, signal that new memory space is available
                if Self.totalByteBufferSize! <= maximumTotalLogStorageSize {
                    // Only signal if the semaphore count is below 0 (so at least one thread is blocked)
                    if Self.semaphoreCounter < 0 {
                        Self.semaphoreCounter += 1
                        Self.semaphore.signal()
                    }
                }
                
                Self.totalByteBufferSize! -= Self.byteBuffer!.capacity
                
                Self.byteBufferLock.unlock()
            }
    }
}
