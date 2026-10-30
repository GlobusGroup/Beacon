//
//  Item.swift
//  Beacon
//
//  Created by Dean Ward on 30/10/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
