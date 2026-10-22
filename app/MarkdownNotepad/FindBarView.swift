import SwiftUI

struct FindBarView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var controller: FindController
    @FocusState private var queryFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find", text: $controller.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 220)
                .focused($queryFocused)
                .onSubmit { controller.next() }
                .accessibilityIdentifier("findField")

            statusLabel

            Button(action: controller.previous) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(controller.matchCount == 0)
            .help("Previous match (⇧⌘G)")

            Button(action: controller.next) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(controller.matchCount == 0)
            .help("Next match (⌘G)")

            Button {
                controller.isCaseSensitive.toggle()
            } label: {
                Text("Aa")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 22)
            }
            .buttonStyle(.borderless)
            .background(controller.isCaseSensitive ? Color.accentColor.opacity(0.2) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help("Match case")

            Button {
                controller.isRegex.toggle()
            } label: {
                Text(".*")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 22)
            }
            .buttonStyle(.borderless)
            .background(controller.isRegex ? Color.accentColor.opacity(0.2) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help("Use regular expression")

            if controller.showReplace {
                TextField("Replace", text: $controller.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, idealWidth: 180)
                    .accessibilityIdentifier("replaceField")

                Button("Replace") { controller.replaceCurrent() }
                    .disabled(controller.matchCount == 0)
                Button("All") { controller.replaceAll() }
                    .disabled(controller.matchCount == 0)
            } else {
                Button("Replace") {
                    controller.showReplace = true
                }
                .buttonStyle(.link)
            }

            Spacer()

            Button {
                session.hideFind()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close find bar")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { queryFocused = true }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let error = controller.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(error)
        } else if controller.query.isEmpty {
            Text("")
                .font(.caption)
        } else if controller.matchCount == 0 {
            Text("No matches")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(controller.currentIndex + 1) of \(controller.matchCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("findMatchCount")
                .accessibilityLabel(Text("\(controller.currentIndex + 1) of \(controller.matchCount)"))
        }
    }
}
