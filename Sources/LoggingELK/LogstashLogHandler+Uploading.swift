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
    func scheduleUploadTask(initialDelay: TimeAmount) -> RepeatedTask {
        eventLoopGroup
            .next()
            .scheduleRepeatedTask(
                initialDelay: initialDelay,
                delay: uploadInterval,
                notifying: nil, upload
            )
    }

    private func upload(_ task: RepeatedTask? = nil) throws {
        guard self.byteBuffer.readableBytes != 0 else {
            return
        }

        var tempByteBuffer = ByteBuffer()

        self.byteBufferLock.lock()

        // Copy log data into a temporary byte buffer
        // This helps to prevent a stalling request if more than the max. buffer size
        // log messages are created during uploading of the "old" log data
        tempByteBuffer = ByteBufferAllocator().buffer(capacity: self.byteBuffer.readableBytes)
        tempByteBuffer.writeBuffer(&self.byteBuffer)

        self.byteBuffer.clear()

        self.byteBufferLock.unlock(withValue: false)

        // Read data from temp byte buffer until it doesn't contain any readable bytes anymore
        while tempByteBuffer.readableBytes != 0 {
            guard let logDataSize: Int = tempByteBuffer.readInteger(),
                  let logData = tempByteBuffer.readSlice(length: logDataSize) else {
                fatalError("Error reading log data from byte buffer")
            }

            var httpRequest: HTTPClient.Request

            if self.httpRequest != nil {
                httpRequest = self.httpRequest!
            } else {
                httpRequest = createHTTPRequest()
            }

            httpRequest.body = .byteBuffer(logData)

            self.httpClient.execute(request: httpRequest).whenComplete { result in
                switch result {
                case .failure(let error):
                    self.backgroundActivityLogger.log(level: .warning,
                                                      "Error during sending logs to Logstash - \(error)",
                                                      metadata: ["hostname": .string(self.hostname),
                                                                 "port": .string(String(describing: self.port)),
                                                                 "label": .string(self.label)])
                case .success(let response):
                    if response.status != .ok {
                        self.backgroundActivityLogger.log(
                            level: .warning,
                            "Error during sending logs to Logstash - \(String(describing: response.status))",
                            metadata: ["hostname": .string(self.hostname),
                                       "port": .string(String(describing: self.port)),
                                       "label": .string(self.label)]
                        )
                    }
                }
            }
        }
    }
}
