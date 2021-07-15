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
    internal func scheduleUploadTask(initialDelay: TimeAmount) -> RepeatedTask {
        // Also store the cancelable here so that it can be cancled during manual uploading
        self.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: initialDelay, delay: uploadInterval, notifying: nil, upload)
    }
    
    private func upload(_ task: RepeatedTask? = nil) throws -> Void {
        /// No log data stored at the moment
        guard self.byteBuffer.readableBytes != 0 else {
            return
        }
        
        /// Extract the stored log data to temporary byte buffer
        var tempByteBuffer = ByteBuffer()
        
        /// Lock regardless of the current state value
        self.lock.lock()
        
        /// Copy out the log data into a temporary byte buffer
        /// This eg. helps to prevent a stalling request if more than the max. buffer size log messages are created DURING uploading of the "old" log data
        /// This can go on multiple times, since the upload task is then (manually) scheduled multiple times, each task with its own log data that will be uploaded
        /// This ensures that no log data is lost and the loghandler can manage a huge spike in log data during uploading the "old" log data (but is basically a edge edge case)
        tempByteBuffer = ByteBufferAllocator().buffer(capacity: self.byteBuffer.readableBytes)
        tempByteBuffer.writeBuffer(&self.byteBuffer)
        
        /// Reset the byte bugger
        self.byteBuffer.clear()
        
        /// Unlock and set the state value to "false", indicating that no copying of data into the temp byte buffer takes place at the moment
        self.lock.unlock(withValue: false)
        
        /// Read data from temp byte buffer until it doesn't contain any readable byte anymore
        while tempByteBuffer.readableBytes != 0 {
            sleep(10)
            
            guard let logDataSize: Int = tempByteBuffer.readInteger(), let logData = tempByteBuffer.readSlice(length: logDataSize) else {
                fatalError("Error reading log data from log storage")
            }
            
            /// HTTP Request not initialized
            guard var httpRequest = self.httpRequest else {
                self.backgroundActivityLogger.log(level: .warning,
                                                  "HTTP request not initialized during sending logs to Logstash",
                                                  metadata: ["hostname":.string(self.hostname),
                                                             "port":.string(String(describing: self.port)),
                                                             "label":.string(self.label)])
                return
            }
            
            /// Set the saved logdata to the body of the request
            httpRequest.body = .byteBuffer(logData)
            
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
}
