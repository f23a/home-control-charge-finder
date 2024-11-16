//
//  FindChargingRangesJob.swift
//  home-control-charge-finder
//
//  Created by Christoph Pageler on 09.11.24.
//

import Foundation
import HomeControlKit
import HomeControlClient
import HomeControlLogging
import Logging

class FindChargingRangesJob: Job {
    private let logger = Logger(homeControl: "charge-finder.find-charging-ranges-job")

    private let homeControlClient: HomeControlClientable
    private var settings: ChargeFinderSettings?

    init(homeControlClient: HomeControlClientable) {
        self.homeControlClient = homeControlClient
        super.init(maxAge: 10.minutes)
    }

    override func run() async {
        do {
            try await catchRun()
        } catch {
            logger.critical("Error: \(error)")
        }
    }

    private func catchRun() async throws {
        try await updateSettings()
        guard let settings else { throw Error.noSettings }
        logger.info("Settings: \(settings)")

        let dateRange = try await detectDateRange()
        logger.info("Date Range \(dateRange)")

        let electricityPrices = try await rangedElectricityPrices(in: dateRange)
        logger.info("Electricity Prices \(electricityPrices.count)")

        let priceGroups = try await findValidElectricityPriceGroups(electricityPrices: electricityPrices)
        logger.info("Price Groups \(priceGroups.count)")
        for group in priceGroups {
            logger.info("Price Group [\(group.items.count)] \(group.formattedRange ?? "") (\(group.rangeTimeInterval ?? -1))")
        }

        let clippedGroups = try await clipElectricityPriceGroups(groups: priceGroups)
        logger.info("Clipped Price Groups \(clippedGroups.count)")
        for clippedGroup in clippedGroups {
            logger.info("Clipped Price Group [\(clippedGroup.items.count)] \(clippedGroup.formattedRange ?? "") (\(clippedGroup.rangeTimeInterval ?? -1))")
        }

        guard !clippedGroups.isEmpty else {
            logger.info("Return early: Clipped Price Groups is empty")
            return
        }

        let forceChargingRanges = try await sendPriceGroupsAsForceChargingRange(groups: clippedGroups)

        try await sendPushMessages(forceChargingRanges: forceChargingRanges)
    }

    private func updateSettings() async throws {
        settings = try await homeControlClient.settings.get(setting: .chargeFinderSetting)
    }

    /// Detect range where to find charging ranges
    /// Range:
    /// - from: max(latestRange, Date())
    /// - to: from + range time interval
    private func detectDateRange() async throws -> Range<Date> {
        guard let settings else { throw Error.noSettings }

        let latestForceChargingRange = try await homeControlClient.forceChargingRanges.latest()
        let rangeFrom = [latestForceChargingRange?.value.endsAt, Date()].compactMap({ $0 }).max()!
        let rangeTo = rangeFrom.addingTimeInterval(settings.rangeTimeInterval)

        return rangeFrom..<rangeTo
    }

    private func rangedElectricityPrices(in dateRage: Range<Date>) async throws -> [RangedElectricityPrice] {
        // Get electricity prices for range
        let electricityPrices = try await homeControlClient.electricityPrice.query(
            .init(
                pagination: .init(page: 0, per: 1000),
                filter: [
                    .startsAt(.init(value: dateRage.lowerBound, method: .greaterThanOrEqual)),
                    .startsAt(.init(value: dateRage.upperBound, method: .lessThanOrEqual))
                ],
                sort: .init(value: .startsAt, direction: .ascending)
            )
        )
        logger.info("Electricity prices in range: \(electricityPrices.items.count)")

        var result: [RangedElectricityPrice] = []
        for (index, electricityPrice) in electricityPrices.items.enumerated() {
            guard let nextElectricityPrice = electricityPrices.items[safe: index + 1] else { break }
            let rangedElectricityPrice = RangedElectricityPrice(
                electricityPrice: electricityPrice,
                range: electricityPrice.value.startsAt..<nextElectricityPrice.value.startsAt.addingTimeInterval(-1)
            )
            result.append(rangedElectricityPrice)
        }
        return result
    }

    private func findValidElectricityPriceGroups(
        electricityPrices: [RangedElectricityPrice]
    ) async throws -> [RangedElectricityPriceGroup] {
        guard let settings else { throw Error.noSettings }

        var result: [RangedElectricityPriceGroup] = []
        var currentGroup: RangedElectricityPriceGroup? = nil

        func addToGroup(electricityPrice: RangedElectricityPrice) {
            var group = currentGroup ?? .init()
            group.items.append(electricityPrice)
            currentGroup = group
        }

        func closeGroup() {
            if let currentGroup {
                result.append(currentGroup)
            }
            currentGroup = nil
        }

        for (index, electricityPrice) in electricityPrices.enumerated() {
            // collect ranges to compare (without current item)
            let compareRanges = electricityPrices.dropFirst(index + 1).prefix(settings.numberOfCompareRanges)

            // ignore ranges at the end, that are smaller than `numberOfCompareRanges`
            guard compareRanges.count == settings.numberOfCompareRanges else {
                continue
            }

            // calcuate sum, average and average percentage value
            let compareRangesSum = compareRanges.map({ $0.electricityPrice.value.total }).reduce(0.0, +)
            let compareRangesAverage = compareRangesSum / Double(compareRanges.count)
            let compareRangesAveragePercentage = compareRangesAverage * settings.compareRangePercentage

            let isBelowAverage = electricityPrice.electricityPrice.value.total < compareRangesAveragePercentage
            let isBelowMaximum = electricityPrice.electricityPrice.value.total <= settings.maximumElectricityPrice
            let isValidRange = isBelowAverage && isBelowMaximum

            let formattedDate = DateFormatter.localizedString(
                from: electricityPrice.electricityPrice.value.startsAt,
                dateStyle: .short,
                timeStyle: .short
            )
            let formattedElectricityPrice = NumberFormatter.localizedString(
                from: NSNumber(value: electricityPrice.electricityPrice.value.total),
                number: .currency
            )
            logger.info("[\(index)] \t \(formattedDate) \t \(formattedElectricityPrice) \t \(isValidRange)")

            if isValidRange {
                addToGroup(electricityPrice: electricityPrice)
            } else {
                closeGroup()
            }
        }
        closeGroup()

        return result
    }

    private func clipElectricityPriceGroups(
        groups: [RangedElectricityPriceGroup]
    ) async throws -> [RangedElectricityPriceGroup] {
        guard let settings else { throw Error.noSettings }

        logger.info("Clip groups to maximum range time interval \(settings.maximumForceChargingRangeTimeInterval)")
        var result: [RangedElectricityPriceGroup] = []
        for group in groups {
            // Remove leading items from the group, as long as groups startAtTimeInterval is above maximum
            var clippedGroup = group
            clippedGroup.clipLeadingItems(maximumRangeTimeInterval: settings.maximumForceChargingRangeTimeInterval)
            logger.info("Clip group \(group.items.count) to \(clippedGroup.items.count)")

            // Ensure that the group has the minimum force charging range time interval from settings
            guard clippedGroup.rangeTimeInterval ?? 0 >= settings.minimumForceChargingRangeTimeInterval else {
                logger.warning("Skip clipped group with \(clippedGroup.items.count): rangeTimeInterval \(clippedGroup.rangeTimeInterval ?? -1) below minimum")
                continue
            }

            result.append(clippedGroup)
        }
        return result
    }

    private func sendPriceGroupsAsForceChargingRange(
        groups: [RangedElectricityPriceGroup]
    ) async throws -> [Stored<ForceChargingRange>] {
        var result: [Stored<ForceChargingRange>] = []

        for group in groups {
            guard let range = group.range else {
                logger.critical("No range for group \(group)")
                continue
            }
            let forceChargingRange = ForceChargingRange(
                startsAt: range.lowerBound,
                endsAt: range.upperBound,
                targetStateOfCharge: 1.0,
                state: .planned,
                source: .automatic
            )
            logger.info("Send force charging range \(forceChargingRange)")
            do {
                let storedForceChargingRange = try await homeControlClient.forceChargingRanges.create(forceChargingRange)
                logger.info("Sent, id: \(storedForceChargingRange.id.uuidString)")
                result.append(storedForceChargingRange)
            } catch {
                logger.critical("Failed to send \(error)")
            }
        }

        return result
    }

    private func sendPushMessages(forceChargingRanges: [Stored<ForceChargingRange>]) async throws {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .none
        dateFormatter.timeStyle = .short

        let formattedDateRanges = forceChargingRanges
            .map { forceChargingRange in
                let formattedStartsAt = dateFormatter.string(from: forceChargingRange.value.startsAt)
                let formattedEndsAt = dateFormatter.string(from: forceChargingRange.value.endsAt)
                return "\(formattedStartsAt) – \(formattedEndsAt)"
            }
            .joined(separator: ", ")
        let message = Message(
            type: .chargeFinderCreatedForceChargingRanges,
            title: "Zwangsladung geplant",
            body: "Es wurden \(forceChargingRanges.count) Zeiträume für die Zwangsladung geplant: \(formattedDateRanges)"
        )
        logger.info("Create Message \(message)")

        let storedMessage = try await homeControlClient.messages.create(message)
        logger.info("Created. ID: \(storedMessage.id)")

        try await homeControlClient.messages.sendPushNotifications(id: storedMessage.id)
        logger.info("Sent")

    }

    enum Error: Swift.Error {
        case noSettings
    }
}

private struct RangedElectricityPrice {
    var electricityPrice: Stored<ElectricityPrice>
    var range: Range<Date>
}

private struct RangedElectricityPriceGroup {
    var items: [RangedElectricityPrice] = []

    var rangeMinimum: Date? { items.map({ $0.range.lowerBound }).min() }

    var rangeMaximum: Date? { items.map({ $0.range.upperBound }).max() }

    var range: Range<Date>? {
        guard let rangeMinimum, let rangeMaximum else { return nil }
        return rangeMinimum..<rangeMaximum
    }

    var rangeTimeInterval: TimeInterval? {
        guard let range else { return nil }
        return range.upperBound.timeIntervalSince(range.lowerBound)
    }

    var formattedRange: String? {
        guard let range else { return nil }

        let lower = DateFormatter.localizedString(from: range.lowerBound, dateStyle: .short, timeStyle: .short)
        let upper = DateFormatter.localizedString(from: range.upperBound, dateStyle: .short, timeStyle: .short)
        return "\(lower) - \(upper)"
    }

    mutating func clipLeadingItems(maximumRangeTimeInterval: TimeInterval) {
        while !items.isEmpty && rangeTimeInterval ?? 0.0 > maximumRangeTimeInterval {
            items.removeFirst()
        }
    }
}
