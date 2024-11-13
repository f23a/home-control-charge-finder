//
//  HomeControlLogHandler.swift
//  home-control-charge-finder
//
//  Created by Christoph Pageler on 09.11.24.
//

import Foundation
import Logging

struct HomeControlLogHandler: LogHandler {
    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { self.metadata[metadataKey] }
        set { self.metadata[metadataKey] = newValue }
    }

    var metadata: Logger.Metadata
    var logLevel: Logger.Level
    var label: String
    var ignoreLabels: [String]

    private let dateFormatter = DateFormatter()

    public init(logLevel: Logger.Level = .info, label: String, ignoreLabels: [String] = []) {
        self.metadata = [:]
        self.logLevel = logLevel
        self.label = label
        self.ignoreLabels = ignoreLabels

        dateFormatter.dateFormat = "HH:mm:ss"
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt)
    {
        guard !ignoreLabels.contains(label) else { return }
        print("[\(level.rawValue.uppercased())] \(dateFormatter.string(from: Date())) \(message)")
    }
}

