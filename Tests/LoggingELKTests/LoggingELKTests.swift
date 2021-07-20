import XCTest
import NIO
@testable import LoggingELK
@testable import Logging

final class LoggingELKTests: XCTestCase {
    private static var logstashHandler: LogstashLogHandler!
    private static var logger: Logger!
    
    /// Setup of the necessary logging backend `LogstashLogHandler` and bootstrap the `LoggingSystem` once for the entire test class
    override class func setUp() {
        // Set high uploadInterval so that the actual uploading never happens
        Self.logstashHandler = LogstashLogHandler(label: "logstash-test", uploadInterval: TimeAmount.seconds(1000), minimumLogStorageSize: 1000)
        
        // Cancle the actual uploading to Logstash
        Self.logstashHandler.uploadTask?.cancel(promise: nil)
        
        LoggingSystem.bootstrap { _ in
            Self.logstashHandler
        }
        
        Self.logger = Logger(label: "test")
    }
    
    /// Clear the internal state of the logging backend `LogstashLogHandler` after each test case
    override func tearDown() {
        super.tearDown()
        
        // Clear metadata
        Self.logstashHandler.metadata.removeAll()
        // Clear the bytebuffer after each test run
        Self.logstashHandler.byteBuffer.clear()
    }
    
    func testSimpleLogging() {
        XCTAssertTrue(Self.logstashHandler.byteBuffer.readableBytes == 0)
        
        Self.logger.error(Logger.Message(stringLiteral: Self.randomString(length: 10)), metadata: [Self.randomString(length: 10): Logger.MetadataValue.string(Self.randomString(length: 10))])
        
        XCTAssertTrue(Self.logstashHandler.byteBuffer.readableBytes > 0)
    }
    
    /// Default log level is .info, so logs with level .trace won't be logged at all
    func testDefaultLogLevel() {
        XCTAssertTrue(Self.logstashHandler.byteBuffer.readableBytes == 0)
        
        // Since default log level is .info, therefore .trace isn't logged
        Self.logger.trace(Logger.Message(stringLiteral: Self.randomString(length: 10)), metadata: [Self.randomString(length: 10): Logger.MetadataValue.string(Self.randomString(length: 10))])
        
        XCTAssertTrue(Self.logstashHandler.byteBuffer.readableBytes == 0)
    }
    
    /// Byte buffer must be at least the passed byte size
    func testByteBufferSize() {
        XCTAssertTrue(Self.logstashHandler.byteBuffer.capacity > 1000)
    }
    
    func testSimpleMetadata() {
        let logMessage = Logger.Message(stringLiteral: Self.randomString(length: 10))
        let logMetadata: Logger.Metadata = [Self.randomString(length: 10): .string(Self.randomString(length: 10))]
        
        Self.logger.error(logMessage, metadata: logMetadata)
        
        guard let logDataSize: Int = Self.logstashHandler.byteBuffer.readInteger(),
              let logData = Self.logstashHandler.byteBuffer.readSlice(length: logDataSize) else {
            XCTFail("Log data couldn't be read from byte buffer")
            return
        }
        
        guard let logHTTPBody = try? JSONDecoder().decode(LogstashLogHandler.LogstashHTTPBody.self, from: logData) else {
            XCTFail("Error decoding the log HTTP body")
            return
        }
        
        XCTAssertEqual(logHTTPBody.loglevel, .error)
        XCTAssertEqual(logHTTPBody.message, logMessage)
        // Remove "location" metadata value
        var httpBodyMetadata = logHTTPBody.metadata
        httpBodyMetadata.removeValue(forKey: "location")
        XCTAssertEqual(httpBodyMetadata, logMetadata)
    }
    
    func testComplexMetadata() {
        let logMessage = Logger.Message(stringLiteral: Self.randomString(length: 10))
        let logMetadata: Logger.Metadata =
        [
            Self.randomString(length: 10):  .dictionary(
                                                [
                                                    Self.randomString(length: 10): .dictionary(
                                                        [
                                                            Self.randomString(length: 10): .string(Self.randomString(length: 10)),
                                                            Self.randomString(length: 10): .array(
                                                                [
                                                                    .string(Self.randomString(length: 10)),
                                                                    .dictionary(
                                                                        [
                                                                            Self.randomString(length: 10): .array(
                                                                                [
                                                                                    .string(Self.randomString(length: 10))
                                                                                ]
                                                                            )
                                                                        ]
                                                                    )
                                                                ]
                                                            )
                                                        ]
                                                    )
                                                ]
                                            )
        ]
        
        Self.logger.info(logMessage, metadata: logMetadata)
        
        guard let logDataSize: Int = Self.logstashHandler.byteBuffer.readInteger(),
              let logData = Self.logstashHandler.byteBuffer.readSlice(length: logDataSize) else {
            XCTFail("Log data couldn't be read from byte buffer")
            return
        }
        
        guard let logHTTPBody = try? JSONDecoder().decode(LogstashLogHandler.LogstashHTTPBody.self, from: logData) else {
            XCTFail("Error decoding the log HTTP body")
            return
        }
        
        XCTAssertEqual(logHTTPBody.loglevel, .info)
        XCTAssertEqual(logHTTPBody.message, logMessage)
        // Remove "location" metadata value
        var httpBodyMetadata = logHTTPBody.metadata
        httpBodyMetadata.removeValue(forKey: "location")
        XCTAssertEqual(httpBodyMetadata, logMetadata)
    }
    
    func testEmptyMetadata() {
        let logMessage = Logger.Message(stringLiteral: Self.randomString(length: 10))
        let logMetadata: Logger.Metadata =
        [
            Self.randomString(length: 10): .string(""),
            Self.randomString(length: 10): .array([]),
            Self.randomString(length: 10): .dictionary([:])
        ]
        
        Self.logger.info(logMessage, metadata: logMetadata)
        
        guard let logDataSize: Int = Self.logstashHandler.byteBuffer.readInteger(),
              let logData = Self.logstashHandler.byteBuffer.readSlice(length: logDataSize) else {
            XCTFail("Log data couldn't be read from byte buffer")
            return
        }
        
        guard let logHTTPBody = try? JSONDecoder().decode(LogstashLogHandler.LogstashHTTPBody.self, from: logData) else {
            XCTFail("Error decoding the log HTTP body")
            return
        }
        
        XCTAssertEqual(logHTTPBody.loglevel, .info)
        XCTAssertEqual(logHTTPBody.message, logMessage)
        // Remove "location" metadata value
        var httpBodyMetadata = logHTTPBody.metadata
        httpBodyMetadata.removeValue(forKey: "location")
        XCTAssertEqual(httpBodyMetadata, logMetadata)
    }
    
    func testCustomStringConvertibleMetadata() {
        let logMessage = Logger.Message(stringLiteral: Self.randomString(length: 10))
        let logMetadata: Logger.Metadata =
        [
            "thisisatest": .stringConvertible("")
        ]
        
        Self.logger.info(logMessage, metadata: logMetadata)
        
        guard let logDataSize: Int = Self.logstashHandler.byteBuffer.readInteger(),
              let logData = Self.logstashHandler.byteBuffer.readSlice(length: logDataSize) else {
            XCTFail("Log data couldn't be read from byte buffer")
            return
        }
        
        guard let logHTTPBody = try? JSONDecoder().decode(LogstashLogHandler.LogstashHTTPBody.self, from: logData) else {
            XCTFail("Error decoding the log HTTP body")
            return
        }
        
        XCTAssertEqual(logHTTPBody.loglevel, .info)
        XCTAssertEqual(logHTTPBody.message, logMessage)
        // Remove "location" metadata value
        var httpBodyMetadata = logHTTPBody.metadata
        httpBodyMetadata.removeValue(forKey: "location")
        // Since stringConvertible is automatically converted to a string during the encoding process and cannot be transformed back to a stringConvertible since the two can't be differentiated
        let expectedLogMetadata: Logger.Metadata =
        [
            "thisisatest": .string("")
        ]
        XCTAssertEqual(httpBodyMetadata, expectedLogMetadata)
    }
    
    func testMetadataMerging() {
        let logMessage = Logger.Message(stringLiteral: Self.randomString(length: 10))
        let logMetadataLogger: Logger.Metadata =
        [
            Self.randomString(length: 10): .string(Self.randomString(length: 10))
        ]
        let logMetadataFunction: Logger.Metadata =
        [
            Self.randomString(length: 10): .string(Self.randomString(length: 10))
        ]
        
        // Set logger metadata
        Self.logger[metadataKey: logMetadataLogger.first!.key] = logMetadataLogger.first!.value
        // Set metadata for specific log entry via passing the metadata in the function call
        Self.logger.info(logMessage, metadata: logMetadataFunction)
        
        guard let logDataSize: Int = Self.logstashHandler.byteBuffer.readInteger(),
              let logData = Self.logstashHandler.byteBuffer.readSlice(length: logDataSize) else {
            XCTFail("Log data couldn't be read from byte buffer")
            return
        }
        
        guard let logHTTPBody = try? JSONDecoder().decode(LogstashLogHandler.LogstashHTTPBody.self, from: logData) else {
            XCTFail("Error decoding the log HTTP body")
            return
        }
        
        XCTAssertEqual(logHTTPBody.loglevel, .info)
        XCTAssertEqual(logHTTPBody.message, logMessage)
        // Remove "location" metadata value
        var httpBodyMetadata = logHTTPBody.metadata
        httpBodyMetadata.removeValue(forKey: "location")
        // Metadata of the log entry must be equal to the merged metadata of the logger and the function
        XCTAssertEqual(httpBodyMetadata, logMetadataLogger.merging(logMetadataFunction) { (_, new) in new })
    }
    
    func testTooLargeLogEntry() {
        // Log data entry is larger than the size of the byte buffer (1024 byte)
        Self.logger.info(Logger.Message(stringLiteral: Self.randomString(length: 10)),
                         metadata:
                            [
                                Self.randomString(length: 10): .string(Self.randomString(length: 1000))
                            ]
        )
        
        // Goal is that "A single log entry is larger than the configured log storage size" error is printed on stdout
        // But sadly quite hard to test
    }
    
    private static func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in letters.randomElement() ?? "x" })
    }
}
