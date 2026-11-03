import Core
import SwiftUI

/// Monitoring dot + text, then "Checked … ago" and waiting review requests; the error in red.
struct StatusLine: View {
    let status: EngineStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                title.font(.headline)
            }
            caption.font(.caption).foregroundStyle(.secondary)
            if let error = status.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
        }
    }

    private var dotColor: Color {
        if status.lastError != nil { return .red }
        return status.monitoring == .on ? .green : .secondary
    }

    private var title: Text {
        switch status.monitoring {
        case .on: Text("Monitoring", bundle: .resources)
        case .off: Text("Monitoring is off", bundle: .resources)
        case .offUntil(let date): Text("Paused until \(date.formatted(date: .omitted, time: .shortened))", bundle: .resources)
        }
    }

    private var caption: Text {
        let checked = status.lastTickAt.map { Text("Checked \(RelativeDate(date: $0).body)", bundle: .resources) }
            ?? Text("Not checked yet", bundle: .resources)
        let waiting = status.openReviewRequests.count
        guard waiting > 0 else { return checked }
        let waitingText = waiting == 1
            ? Text("1 review request waiting", bundle: .resources)
            : Text("\(waiting) review requests waiting", bundle: .resources)
        return Text("\(checked) · \(waitingText)", bundle: .resources)
    }
}
