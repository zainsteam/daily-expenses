import SwiftUI
import SwiftData

struct EntryEditor: View {
    let entry: Entry?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Prefs.self) private var prefs
    @Query(sort: \EntryCategory.sortOrder) private var categories: [EntryCategory]

    @State private var kind: EntryKind = .expense
    @State private var amountText = ""
    @State private var categoryId = ""
    @State private var method: PayMethod = .cash
    @State private var date = Date()
    @State private var note = ""
    @State private var errorText: String?
    @State private var loaded = false
    @State private var confirmDelete = false
    @FocusState private var amountFocused: Bool

    // Switching type picks that type's last category and method, as the web app did.
    // The top picker shows Investment for both putting money in and taking it out.
    private var kindBinding: Binding<EntryKind> {
        Binding(get: { kind.isInvestment ? .investment : kind }, set: { newKind in
            guard newKind != (kind.isInvestment ? .investment : kind) else { return }
            kind = newKind
            categoryId = visibleCategoryId(prefs.lastCategory(newKind), kind: newKind)
            method = prefs.lastMethod(newKind)
            errorText = nil
        })
    }

    // Put in / Take out keeps the chosen investment category.
    private var directionBinding: Binding<EntryKind> {
        Binding(get: { kind }, set: { kind = $0; errorText = nil })
    }

    private var methodTitle: String {
        switch kind {
        case .expense: return "Paid with"
        case .income, .withdrawal: return "Received in"
        case .investment: return "Paid from"
        case .transfer: return "Move money"
        }
    }

    private func visibleCategoryId(_ id: String, kind: EntryKind) -> String {
        categories.first { $0.id == id && $0.kind == kind.categoryKind && !$0.archived }?.id ?? ""
    }

    var body: some View {
        let visible = categories.filter { $0.kind == kind.categoryKind && (!$0.archived || $0.id == categoryId) }

        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: kindBinding) {
                        ForEach(EntryKind.pickable) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if kind.isInvestment {
                    Section {
                        Picker("Direction", selection: directionBinding) {
                            Text("Put in").tag(EntryKind.investment)
                            Text("Take out").tag(EntryKind.withdrawal)
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(kind == .investment
                             ? "Money into a plot, BC, gold or savings. Not counted as spending."
                             : "Money coming back, like a BC payout or selling gold. Not counted as income.")
                    }
                }

                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Money.symbol(prefs.currency)).font(.title2).foregroundStyle(.secondary)
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .focused($amountFocused)
                            .accessibilityLabel("Amount")
                    }
                    // Shown right under the amount so it is visible without scrolling.
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.subheadline)
                    }
                }

                if kind.needsCategory {
                Section("Category") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(visible) { c in
                            let selected = c.id == categoryId
                            Button { categoryId = c.id } label: {
                                Text(c.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 6)
                                    .background(selected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                }

                if kind == .transfer {
                    // `method` is the account the money leaves; it lands in the other one.
                    Section {
                        Picker("Direction", selection: $method) {
                            Text("Bank → Cash").tag(PayMethod.bank)
                            Text("Cash → Bank").tag(PayMethod.cash)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text(methodTitle)
                    } footer: {
                        Text(method == .bank
                             ? "Like taking cash out of an ATM. Not counted as spending or income."
                             : "Like depositing cash in the bank. Not counted as spending or income.")
                    }
                } else {
                    Section(methodTitle) {
                        Picker("Method", selection: $method) {
                            ForEach(PayMethod.selectable) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                }

                if entry != nil {
                    Section {
                        Button("Delete entry", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle((entry == nil ? "Add " : "Edit ") + kind.label.lowercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(entry == nil ? "Add" : "Save") { save() }.bold()
                }
            }
            .keyboardDoneButton()
            .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteEntry() }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let e = entry {
            kind = EntryKind(rawValue: e.kind) ?? .expense
            amountText = Money.toInput(e.amount)
            categoryId = e.categoryId
            method = e.account
            date = Day.date(e.date)
            note = e.note
        } else {
            kind = .expense
            categoryId = visibleCategoryId(prefs.lastCategory(.expense), kind: .expense)
            method = prefs.lastMethod(.expense)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { amountFocused = true }
        }
    }

    private func save() {
        let parsed = Money.read(amountText, currency: prefs.currency)
        if let message = parsed.error { errorText = message; return }
        guard let amount = parsed.value, amount > 0 else { errorText = "Enter an amount greater than zero."; return }
        var catId = ""
        if kind.needsCategory {
            guard let cat = categories.first(where: { $0.id == categoryId }), cat.kind == kind.categoryKind else {
                errorText = "Choose a category."
                return
            }
            catId = cat.id
        }
        let method = self.method.account
        let iso = Day.iso(date)
        let now = Prefs.nowMs()
        let cleanNote = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Limits.noteMax))

        if let e = entry {
            e.kind = kind.rawValue
            e.amount = amount
            e.categoryId = catId
            e.method = method.rawValue
            e.date = iso
            e.note = cleanNote
            e.updatedAt = now
        } else {
            context.insert(Entry(kind: kind.rawValue, amount: amount, categoryId: catId, method: method.rawValue,
                                 date: iso, note: cleanNote, createdAt: now, updatedAt: now))
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            errorText = "Couldn’t save: \(error.localizedDescription)"
            return
        }
        prefs.remember(kind: kind, method: method, categoryId: catId)
        prefs.touch()
        dismiss()
    }

    private func deleteEntry() {
        guard let e = entry else { return }
        context.delete(e)
        do {
            try context.save()
        } catch {
            context.rollback()
            errorText = "Couldn’t delete: \(error.localizedDescription)"
            return
        }
        prefs.touch()
        dismiss()
    }
}
