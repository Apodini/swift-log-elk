//
//  LogstashLogHandler+LogFormatting.swift
//  
//
//  Created by Philipp Zagar on 15.07.21.
//

import Logging

extension LogstashLogHandler {
    func mergeMetadata(passedMetadata: Logger.Metadata?,
                       file: String,
                       function: String,
                       line: UInt) -> Logger.Metadata {
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
