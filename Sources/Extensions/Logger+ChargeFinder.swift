//
//  Logger+ChargeFinder.swift
//  home-control-charge-finder
//
//  Created by Christoph Pageler on 09.11.24.
//


import Logging

extension Logger {
    init(chargeFinder label: String) {
        self.init(label: "de.pageler.christoph.home-control.charge-finder.\(label)")
    }
}
