//
//  LogstashLogHandler+LogFormatting.swift
//  
//
//  Created by Philipp Zagar on 15.07.21.
//

import Foundation
import Logging


extension LogstashLogHandler {
    #warning("Do we need to use this unsafe memory access here? Can we also use a `DateFormatter` here?")
    var timestamp: String {
        var buffer = [Int8](repeating: 0, count: 255)
        var timestamp = time(nil)
        let localTime = localtime(&timestamp)
        strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S%z", localTime)
        return buffer.withUnsafeBufferPointer {
            $0.withMemoryRebound(to: CChar.self) {
                String(cString: $0.baseAddress!) // swiftlint:disable:this force_unwrapping
            }
        }
    }
    
    
    internal func mergeMetadata(passedMetadata: Logger.Metadata?, file: String, function: String, line: UInt) -> Logger.Metadata {
        // Merge metadata
        var mergedMetadata = self.metadata.merging(passedMetadata ?? [:]) { $1 }
        // Add code location to metdata
        mergedMetadata["location"] = .string(formatLocation(file: file, function: function, line: line))
        
        return mergedMetadata
    }
    
    
    private func conciseSourcePath(_ path: String) -> String {
        path.split(separator: "/")
            .split(separator: "Sources")
            .last?
            .joined(separator: "/") ?? path
    }
    
    private func formatLocation(file: String, function: String, line: UInt) -> String {
        "\(self.conciseSourcePath(file)) ▶ \(function) ▶ \(line)"
    }
}
