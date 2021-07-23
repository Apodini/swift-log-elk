//
//  LogstashLogHandler+LogFormatting.swift
//  
//
//  Created by Philipp Zagar on 15.07.21.
//

import Logging

extension LogstashLogHandler {
    /// Merges the `Logger.Metadata` passed via the `.log()` function call as well
    /// as the metadata set directly on the logger (eg. via `logger[metadatakey: "test"] = "test"`
    /// Furthermore, it formats and adds the code location of the logging call to the `Logger.Metadata`
    func mergeMetadata(passedMetadata: Logger.Metadata?,
                       file: String,
                       function: String,
                       line: UInt) -> Logger.Metadata {
        var mergedMetadata = self.metadata.merging(passedMetadata ?? [:]) { $1 }
        // Add code location to metdata
        mergedMetadata["location"] = .string(formatLocation(file: file, function: function, line: line))
        // Remove "super-secret-is-a-logstash-loghandler" from actually logged metadata
        mergedMetadata.removeValue(forKey: "super-secret-is-a-logstash-loghandler")

        return mergedMetadata
    }

    /// Splits the source code file path so that only the relevant path is logged
    private func conciseSourcePath(_ path: String) -> String {
        path.split(separator: "/")
            .split(separator: "Sources")
            .last?
            .joined(separator: "/") ?? path
    }

    /// Formats the code location properly
    private func formatLocation(file: String, function: String, line: UInt) -> String {
        "\(self.conciseSourcePath(file)) ▶ \(function) ▶ \(line)"
    }
}
