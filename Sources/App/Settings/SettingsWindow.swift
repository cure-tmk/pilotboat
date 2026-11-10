import SwiftUI

struct SettingsWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label(String(localized: "General", bundle: .resources), systemImage: "gearshape") }
            AccountTab().tabItem { Label(String(localized: "Account", bundle: .resources), systemImage: "person.crop.circle") }
            LaunchersTab().tabItem { Label(String(localized: "Launchers", bundle: .resources), systemImage: "terminal") }
            DataTab().tabItem { Label(String(localized: "Data", bundle: .resources), systemImage: "externaldrive") }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.lastErrorMessage != nil {
                ErrorBanner(message: Bindable(model).lastErrorMessage).padding(.horizontal, 16).padding(.top, 8)
            }
        }
        .frame(width: 600)
        .frame(minHeight: 380)
    }
}
