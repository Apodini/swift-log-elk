//
//  XCTestCase+FatalError.swift
//
//  Created by Philipp Zagar on 27.07.21.
//

import XCTest
@testable import LoggingELK

extension XCTestCase {
    func expectFatalError(expectedMessage: String, testcase: @escaping () -> Void) {
        
        // arrange
        let expectation = self.expectation(description: "expectingFatalError")
        var assertionMessage: String? = nil
        
        // override fatalError. This will terminate thread when fatalError is called.
        FatalErrorUtil.replaceFatalError { message, _, _ in
            assertionMessage = message
            expectation.fulfill()
            // Terminate the current thread after expectation fulfill
            Thread.exit()
            // Since current thread was terminated this code never be executed
            fatalError("It will never be executed")
        }
        
        // act, perform on separate thread to be able terminate this thread after expectation fulfill
        Thread(block: testcase).start()
        
        waitForExpectations(timeout: 0.1) { _ in
            // assert
            XCTAssertEqual(assertionMessage, expectedMessage)
            
            // clean up
            FatalErrorUtil.restoreFatalError()
        }
    }
}
