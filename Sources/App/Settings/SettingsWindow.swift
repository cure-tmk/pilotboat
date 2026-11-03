import SwiftUI

struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label(String(localized: "General", bundle: .resources), systemImage: "gearshape") }
            AccountTab().tabItem { Label(String(localized: "Account", bundle: .resources), systemImage: "person.crop.circle") }
            LaunchersTab().tabItem { Label(String(localized: "Launchers", bundle: .resources), systemImage: "terminal") }
            DataTab().tabItem { Label(String(localized: "Data", bundle: .resources), systemImage: "externaldrive") }
        }
        .frame(width: 600)
        .frame(minHeight: 380)
    }
}
