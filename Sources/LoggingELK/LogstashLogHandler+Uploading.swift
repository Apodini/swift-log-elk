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
    func scheduleUploadTask(initialDelay: TimeAmount) -> RepeatedTask {
        eventLoopGroup
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
    func uploadLogData(_ task: RepeatedTask? = nil) {       // swiftlint:disable:this cyclomatic_complexity function_body_length
        guard self.byteBuffer.readableBytes != 0 else {
            return
        }
        
        // If total byte buffer size is exceeded, wait until the size is decreased again
        if self.totalByteBufferSize + self.byteBuffer.capacity > self.maximumTotalLogStorageSize {
            self.semaphoreCounter -= 1
            self.semaphore.wait()
        }
        
        self.byteBufferLock.lock()
        
        self.totalByteBufferSize += self.byteBuffer.capacity
        
        // Copy log data into a temporary byte buffer
        // This helps to prevent a stalling request if more than the max. buffer size
        // log messages are created during uploading of the "old" log data
        var tempByteBuffer = ByteBufferAllocator().buffer(capacity: self.byteBuffer.readableBytes)
        tempByteBuffer.writeBuffer(&self.byteBuffer)
        
        self.byteBuffer.clear()
        
        if self.httpRequest == nil {
            self.httpRequest = createHTTPRequest()
        }
        
        var pendingHTTPRequests: [EventLoopFuture<HTTPClient.Response>] = []
        
        // Read data from temp byte buffer until it doesn't contain any readable bytes anymore
        while tempByteBuffer.readableBytes != 0 {
            guard let logDataSize: Int = tempByteBuffer.readInteger(),
                  let logData = tempByteBuffer.readSlice(length: logDataSize) else {
                      fatalError("Error reading log data from byte buffer")
                  }
            
            guard var httpRequest = self.httpRequest else {
                fatalError("HTTP Request not properly initialized")
            }
            
            httpRequest.body = .byteBuffer(logData)
            
            pendingHTTPRequests.append(self.httpClient.execute(request: httpRequest))
        }
        
        self.byteBufferLock.unlock(withValue: false)
        
        _ = EventLoopFuture<HTTPClient.Response>
            .whenAllComplete(pendingHTTPRequests, on: self.eventLoopGroup.next())
            .map { results in
                _ = results.map { result in
                    switch result {
                    case .failure(let error):
                        self.backgroundActivityLogger.log(
                            level: .warning,
                            "Error during sending logs to Logstash - \(error)",
                            metadata: [
                                "label": .string(self.label),
                                "hostname": .string(self.hostname),
                                "port": .string(String(describing: self.port))
                            ]
                        )
                    case .success(let response):
                        if response.status != .ok {
                            self.backgroundActivityLogger.log(
                                level: .warning,
                                "Error during sending logs to Logstash - \(String(describing: response.status))",
                                metadata: [
                                    "label": .string(self.label),
                                    "hostname": .string(self.hostname),
                                    "port": .string(String(describing: self.port))
                                ]
                            )
                        }
                    }
                }
                
                self.byteBufferLock.lock()
                
                // Once all HTTP requests are completed, signal that new memory space is available
                if self.totalByteBufferSize <= self.maximumTotalLogStorageSize {
                    // Only signal if the semaphore count is below 0 (so at least one thread is blocked)
                    if self.semaphoreCounter < 0 {
                        self.semaphoreCounter += 1
                        self.semaphore.signal()
                    }
                }
                
                self.totalByteBufferSize -= self.byteBuffer.capacity
                
                self.byteBufferLock.unlock()
            }
    }
}
