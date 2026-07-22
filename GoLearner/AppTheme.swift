//
//  AppTheme.swift
//  GoLearner
//
//  User-selectable app appearance: follow the system, or force light/dark.
//  Persisted via @AppStorage in RootView and applied with
//  .preferredColorScheme; `.system` maps to nil (defer to the OS).
//

import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    /// The scheme to force, or nil to follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}
