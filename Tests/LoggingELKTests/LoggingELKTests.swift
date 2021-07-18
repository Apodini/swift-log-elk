import XCTest
import NIO
@testable import LoggingELK
@testable import Logging

final class LoggingELKTests: XCTestCase {
    private static var logstashHandler = LogstashLogHandler(label: "logstash-test")
    private static var logger = Logger(label: "test")
    
    /// Setup of the necessary logging backend `LogstashLogHandler` and bootstrap the `LoggingSystem`
    override class func setUp() {
        // Set high uploadInterval so that the actual uploading never happens
        Self.logstashHandler = LogstashLogHandler(label: "logstash-test", uploadInterval: TimeAmount.seconds(1000), minimumLogStorageSize: 1000)
        
        // Cancle the actual uploading to Logstash
        Self.logstashHandler.uploadTask?.cancel(promise: nil)
        
        LoggingSystem.bootstrap { label in
            Self.logstashHandler
        }
        
        Self.logger = Logger(label: "test")
    }
    
    /// Clear the bytebuffer after each test run
    override func tearDown() {
        Self.logstashHandler.byteBuffer.clear()
    }
    
    func testSimpleLogging() {
        XCTAssertTrue(Self.logstashHandler.byteBuffer.readableBytes == 0)
        
        Self.logger.error("test", metadata: ["testMetadata":.string("test")])
        
        XCTAssertTrue(Self.logstashHandler.byteBuffer.readableBytes > 0)
    }
    
    /// Default log level is .info, so logs with level .trace won't be logged at all
    func testDefaultLogLevel() {
        XCTAssertTrue(Self.logstashHandler.byteBuffer.readableBytes == 0)
        
        /// Since default log level is .info, therefore .trace isn't logged
        Self.logger.trace("test", metadata: ["testMetadata":.string("test")])
        
        XCTAssertTrue(Self.logstashHandler.byteBuffer.readableBytes == 0)
    }
    
    /// Byte buffer must be at least the passed byte size
    func testByteBufferSize() {
        XCTAssertTrue(Self.logstashHandler.byteBuffer.capacity > 1000)
    }
    
    private static func randomString(length: Int) -> String {
      let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      return String((0..<length).map{ _ in letters.randomElement()! })
    }
}
