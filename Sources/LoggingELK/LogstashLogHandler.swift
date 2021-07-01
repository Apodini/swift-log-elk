//
//  LogstashLogHandler.swift
//
//
//  Created by Philipp Zagar on 26.06.21.
//

import Foundation
import Logging
import AsyncHTTPClient

/// `LogstashLogHandler` is a simple implementation of `LogHandler` for directing
/// `Logger` output to Logstash via HTTP requests
public struct LogstashLogHandler: LogHandler {
    private struct LogstashHTTPBody: Encodable {
        let post_date: String
        let loglevel: Logger.Level
        let message: String
        let metadata: String
        let source: String
        let file: String
        let function: String
        let line: UInt
    }
    
    //private let httpClient: HTTPClient
    private let label: String
    private let app: Application
    private let hostname: String
    private let port: Int
    
    //private var inFlight: Bool = false

    public var logLevel: Logger.Level = .info

    private var prettyMetadata: String?
    
    public var metadata = Logger.Metadata() {
        didSet {
            self.prettyMetadata = self.prettify(self.metadata)
        }
    }

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            return self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    internal init(label: String, app: Application, hostname: String, port: Int) {
        self.label = label
        self.app = app
        self.hostname = hostname
        self.port = port
    }
    
    /// Factory that makes a `LogstashLogHandler` to directs its output to Logstash
    public static func logstashOutput(label: String, app: Application, hostname: String = "127.0.0.1", port: Int = 31311) -> LogstashLogHandler {
        return LogstashLogHandler(label: label, app: app, hostname: hostname, port: port)
    }

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
//        let prettyMetadata = metadata?.isEmpty ?? true
//            ? self.prettyMetadata
//            : self.prettify(self.metadata.merging(metadata!, uniquingKeysWith: { _, new in new }))
//
//        var stream = self.stream
//        stream.write("\(self.timestamp()) \(level) \(self.label) :\(prettyMetadata.map { " \($0)" } ?? "") \(message)\n")
        
//        defer {
//            try? httpClient.syncShutdown()
//        }
        
        do {
            var request = try HTTPClient.Request(url: "http://\(hostname):\(port)", method: .POST)
            request.headers.add(name: "Content-Type", value: "application/json")
            request.headers.add(name: "Accept", value: "application/json")
            // Maybe also a keep-alive header to keep the connection open
            request.headers.add(name: "Connection", value: "keep-alive")
            request.headers.add(name: "Keep-Alive", value: "timeout=300, max=1000")
            
            let bodyObject = LogstashHTTPBody(post_date: timestamp(),
                                              loglevel: level,
                                              message: message.description,
                                              metadata: prettyMetadata ?? "",
                                              source: source,
                                              file: file,
                                              function: function,
                                              line: line)
            
            let bodyJSON = try JSONEncoder().encode(bodyObject)
            request.body = .data(bodyJSON)

            //self.inFlight = true
            
            self.app.httpClient.execute(request: request).whenComplete { result in
                switch result {
                case .failure(let error):
                    //self.inFlight = false
                    print("Error! - failure to connect - \(error)")
                case .success(let response):
                    //self.inFlight = false
                    if response.status == .ok {
                        print("Success!")
                    } else {
                        print("Error! - \(String(describing: response.status))")
                    }
                }
            }
        } catch {
            print("Error! - Failure in catch clause - \(error)")
        }
        
        //try? httpClient.syncShutdown()
    }

    private func prettify(_ metadata: Logger.Metadata) -> String? {
        return !metadata.isEmpty
            ? metadata.lazy.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: " ")
            : nil
    }

    private func timestamp() -> String {
        var buffer = [Int8](repeating: 0, count: 255)
        var timestamp = time(nil)
        let localTime = localtime(&timestamp)
        strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S%z", localTime)
        return buffer.withUnsafeBufferPointer {
            $0.withMemoryRebound(to: CChar.self) {
                String(cString: $0.baseAddress!)
            }
        }
    }
}
