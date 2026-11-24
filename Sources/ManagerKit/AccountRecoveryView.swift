import SwiftUI
import AppKit

struct AccountRecoveryView: View {
    @ObservedObject var model: Manager
    @State private var selectedUser = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover a password").font(.title2.bold())
            if !model.accountCapabilities.contains("account-recovery") {
                Text("This server version does not support account recovery from the app. Update Switchboard, then start it again.").fixedSize(horizontal: false, vertical: true)
            } else {
                Text("As the owner of this local installation, you can help a user choose a new password.").fixedSize(horizontal: false, vertical: true)
                if !model.accountUsers.isEmpty {
                    Picker("Account", selection: $selectedUser) {
                        Text("Choose an account").tag("")
                        ForEach(model.accountUsers) { user in Text(user.username).tag(user.id) }
                    }.disabled(model.accountBusy)
                    Text("Your Mac will ask you to authenticate. A one-time link then opens in your browser and expires after 10 minutes. Completing recovery signs this user out of existing sessions; their data is kept.").font(.callout).foregroundStyle(Color(nsColor: .labelColor).opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                } else if model.accountBusy { ProgressView("Loading accounts…").controlSize(.small) }
                else { Text("No enabled local accounts are available.") }
                if let error = model.accountError { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true); Button("Reload Accounts") { model.loadRecoveryAccounts() }.disabled(model.accountBusy) }
                if let notice = model.accountNotice { Label(notice, systemImage: "checkmark.circle").fixedSize(horizontal: false, vertical: true) }
            }
            HStack {
                if model.accountNotice != nil {
                    Spacer()
                    Button("Done") { model.dismissRecovery() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { model.dismissRecovery() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if model.accountCapabilities.contains("account-recovery") {
                        Button(model.accountBusy ? "Please wait…" : "Authenticate & Recover") { model.recoverPassword(userId: selectedUser) }
                            .buttonStyle(.borderedProminent).disabled(model.accountBusy || selectedUser.isEmpty).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }.padding(24).frame(width: 390).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { selectedUser = model.accountUsers.first?.id ?? "" }
        .onChange(of: model.accountUsers) { _, users in
            if !users.contains(where: { $0.id == selectedUser }) { selectedUser = users.first?.id ?? "" }
        }
    }
}
