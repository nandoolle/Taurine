//
//  TaurineApp.swift
//  Taurine
//
//  Created by Dominic Rodemer on 11.11.25.
//

import AppKit

@main
struct TaurineApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Preferences is owned by MenuBarController; no extra SwiftUI scene is needed.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
