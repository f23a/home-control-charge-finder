//
//  MainCommand.swift
//  home-control-charge-finder
//
//  Created by Christoph Pageler on 09.11.24.
//

import ArgumentParser
import Foundation
import HomeControlClient
import HomeControlKit
import HomeControlLogging
import Logging

@main
struct MainCommand: AsyncParsableCommand {
    private static let logger = Logger(homeControl: "charge-finder.main-command")

    func run() async throws {
        LoggingSystem.bootstrapHomeControl()

        // Load environment from .env.json
        let dotEnv = try DotEnv.fromWorkingDirectory()

        // Prepare home control client
        var homeControlClient = HomeControlClient.localhost
        homeControlClient.authToken = try dotEnv.require("AUTH_TOKEN")

        // Prepare jobs
        let jobs: [Job] = [
            FindChargingRangesJob(homeControlClient: homeControlClient)
        ]

        // run jobs until command is canceled using ctrl + c
        while true {
            for job in jobs {
                await job.runIfNeeded(at: Date())
            }
            await Task.sleep(1.seconds)
        }
    }
}
