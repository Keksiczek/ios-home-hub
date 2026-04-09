import Foundation
import SwiftUI

@MainActor
final class SettingsService: ObservableObject {
    @Published private(set) var current: AppSettings = .default
    private let store: any Store

    init(store: any Store) {
        self.store = store
    }

    func load() async {
        if let saved = try? await store.loadAppSettings() {
            current = saved
        }
    }

    func update(_ settings: AppSettings) async {
        current = settings
        try? await store.save(settings: settings)
    }

    func set<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>, to value: Value) async {
        var next = current
        next[keyPath: keyPath] = value
        await update(next)
    }
}
