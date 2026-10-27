import SwiftUI

struct PaletteView: View {
    @Bindable var model: PaletteModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search apps, windows and tabs", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            // Placeholder until providers land (M2: apps + windows, M3: tabs).
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Nothing indexed yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Apps and windows arrive in M2, tabs in M3.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            Divider()

            HStack {
                Spacer()
                Text("⇧⇧ toggle   esc close")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.showCount) { searchFocused = true }
    }
}
