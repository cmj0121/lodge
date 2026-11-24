import LodgeKit
import SwiftUI

/// The workspace on screen's search engine, and "Rest tabs after" for every workspace, as on the Mac.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RestAfter.defaultsKey) private var restMinutes = RestAfter.standard.rawValue

    var body: some View {
        let catalog = model.catalog
        NavigationStack {
            Form {
                Section {
                    Picker(
                        "Search with",
                        selection: Binding(
                            get: { catalog.followsDefault ? nil : catalog.engine.id },
                            set: { model.chooseEngine($0) })
                    ) {
                        if model.active.kind == .custom {
                            let followed = model.search.catalog(for: model.workspaces.default).engine
                            Text("Follow Default (\(followed.name))").tag(String?.none)
                        }
                        ForEach(catalog.available) { engine in
                            Text(engine.name).tag(Optional(engine.id))
                        }
                    }
                } header: {
                    Label(model.active.name, systemImage: model.active.symbol)
                }
                Section {
                    Picker("Rest tabs after", selection: $restMinutes) {
                        ForEach(RestAfter.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                } footer: {
                    Text("A tab you have not looked at for this long gives up its memory, and picks up where it was when you come back.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension RestAfter {
    fileprivate var title: String {
        switch self {
        case .five: String(localized: "5 minutes")
        case .fifteen: String(localized: "15 minutes")
        case .thirty: String(localized: "30 minutes")
        case .sixty: String(localized: "60 minutes")
        case .never: String(localized: "Never")
        }
    }
}
