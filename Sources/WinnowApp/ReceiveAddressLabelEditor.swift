import SwiftUI

struct ReceiveAddressLabelEditor: View {
    let address: String
    let finish: () -> Void
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var existing: String? { model.receiveAddressLabel(for: address) }
    private var validLabel: String? { try? ReceiveAddressLabelStore.normalizedLabel(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Who is this address for?").font(.title2.bold())
            Text("Name the person you’re sharing it with, or what the payment is for. This note will appear beside payments to this address.")
            TextField("Alice · invoice 12", text: $draft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit { focused = false }
                .accessibilityIdentifier("receiveAddressLabelField")
            Text("Only saved on this device. The label is not included when you copy or share the address, and does not verify who paid you.")
                .font(.footnote).foregroundStyle(.secondary)
            if validLabel == nil {
                Text(ReceiveAddressLabelStore.StorageError.invalidLabel.localizedDescription)
                    .foregroundStyle(.red)
            }
            if let notice = model.receiveLabelStorageNotice {
                Text(notice).foregroundStyle(.orange)
            }
            if let error {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("receiveLabelError")
            }
            Button(existing == nil ? "Save and show address" : "Save label") { save(draft) }
                .buttonStyle(.borderedProminent)
                .disabled(saving || validLabel == nil || validLabel?.isEmpty == true
                          || model.receiveLabelStorageNotice != nil)
                .accessibilityIdentifier("saveReceiveAddressLabelButton")
            Button(existing == nil ? "Skip for now" : "Cancel") { finish() }
                .disabled(saving)
                .accessibilityIdentifier("skipReceiveAddressLabelButton")
            if existing != nil {
                Button("Remove label", role: .destructive) { save("") }
                    .disabled(saving || model.receiveLabelStorageNotice != nil)
                    .accessibilityIdentifier("removeReceiveAddressLabelButton")
            }
        }
        .task { draft = existing ?? "" }
    }

    private func save(_ label: String) {
        guard !saving else { return }
        saving = true
        focused = false
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.setReceiveAddressLabel(label, address: address)
                finish()
            } catch { self.error = error.localizedDescription }
        }
    }
}
