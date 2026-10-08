import SwiftUI

struct BreaksView: View {
    @EnvironmentObject private var engine: BreakEngine
    @State private var editorItem: PlannedBreak?
    @State private var showingNewBreak = false

    var body: some View {
        ZStack {
            AmbientBackground(style: .dusk)
            ScrollView {
                VStack(spacing: 18) {
                    intervalSummary
                    plannedSection
                    officeHoursSummary
                }
                .frame(maxWidth: 820)
                .padding()
            }
        }
        .navigationTitle("Breaks")
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: $editorItem) { item in
            NavigationStack {
                PlannedBreakEditor(item: item) { updated in
                    if let index = engine.settings.plannedBreaks.firstIndex(where: { $0.id == updated.id }) {
                        engine.settings.plannedBreaks[index] = updated
                    }
                } onDelete: {
                    engine.settings.plannedBreaks.removeAll { $0.id == item.id }
                }
            }
        }
        .sheet(isPresented: $showingNewBreak) {
            NavigationStack {
                PlannedBreakEditor(
                    item: PlannedBreak(
                        name: "Lunch",
                        symbol: "fork.knife",
                        hour: 13,
                        minute: 0,
                        duration: 15 * 60,
                        weekdays: [2, 3, 4, 5, 6],
                        isEnabled: true
                    ),
                    onSave: { created in
                        engine.settings.plannedBreaks.append(created)
                    },
                    onDelete: nil
                )
            }
        }
    }

    private var intervalSummary: some View {
        NavigationLink {
            ScreenBreakSettingsView()
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SettingsGlyph(icon: "eyes", color: BreakPalette.magenta)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Interval breaks").font(.headline)
                        Text("Your everyday screen rhythm").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                HStack(spacing: 12) {
                    SummaryTile(value: engine.settings.workInterval.compactDuration, label: "Focus")
                    SummaryTile(value: engine.settings.shortBreakDuration.compactDuration, label: "Break")
                    SummaryTile(value: engine.settings.longBreakEnabled ? "Every \(engine.settings.longBreakFrequency)" : "Off", label: "Long break")
                }
            }
            .glassCard()
        }
        .buttonStyle(.plain)
    }

    private var plannedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Planned breaks").font(.title3.bold())
                    Text("Fixed moments worth protecting").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingNewBreak = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
            if engine.settings.plannedBreaks.isEmpty {
                ContentUnavailableView("No planned breaks", systemImage: "calendar.badge.plus", description: Text("Add lunch, a walk, or an end-of-day reset."))
                    .glassCard()
            } else {
                ForEach(engine.settings.plannedBreaks) { item in
                    Button { editorItem = item } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.symbol)
                                .font(.title3.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(BreakPalette.coral.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.headline)
                                Text(weekdaySummary(item.weekdays)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(timeString(hour: item.hour, minute: item.minute)).fontWeight(.semibold)
                                Text(item.duration.compactDuration).font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: item.isEnabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isEnabled ? BreakPalette.magenta : .secondary)
                        }
                        .glassCard()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var officeHoursSummary: some View {
        NavigationLink {
            OfficeHoursSettingsView()
        } label: {
            HStack(spacing: 14) {
                SettingsGlyph(icon: "calendar.badge.clock", color: BreakPalette.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Office hours").font(.headline)
                    Text(engine.settings.officeHours.isEnabled ? "\(timeString(hour: engine.settings.officeHours.startHour, minute: engine.settings.officeHours.startMinute))–\(timeString(hour: engine.settings.officeHours.endHour, minute: engine.settings.officeHours.endMinute)) · \(weekdaySummary(engine.settings.officeHours.weekdays))" : "Reminders run all day")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .glassCard()
        }
        .buttonStyle(.plain)
    }
}

struct ScreenBreakSettingsView: View {
    @EnvironmentObject private var engine: BreakEngine

    var body: some View {
        Form {
            Section("General") {
                Stepper(value: $engine.settings.workInterval, in: 60...7200, step: 60) {
                    LabeledContent("Show breaks after", value: engine.settings.workInterval.compactDuration)
                }
                Stepper(value: $engine.settings.shortBreakDuration, in: 5...900, step: 5) {
                    LabeledContent("Break duration", value: engine.settings.shortBreakDuration.compactDuration)
                }
                Toggle("Long breaks", isOn: $engine.settings.longBreakEnabled)
                if engine.settings.longBreakEnabled {
                    Stepper(value: $engine.settings.longBreakDuration, in: 60...7200, step: 60) {
                        LabeledContent("Long break duration", value: engine.settings.longBreakDuration.compactDuration)
                    }
                    Stepper(value: $engine.settings.longBreakFrequency, in: 1...12) {
                        LabeledContent("Every", value: "\(engine.settings.longBreakFrequency) short breaks")
                    }
                }
            }

            Section("Break enforcement") {
                DisciplinePicker(selection: $engine.settings.discipline)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Stepper(value: $engine.settings.snoozesAllowedPerDay, in: 0...20) {
                    LabeledContent("Snoozes allowed per day", value: "\(engine.settings.snoozesAllowedPerDay)")
                }
            }

            Section("More") {
                Toggle("Let me end a break early when nearly done", isOn: $engine.settings.allowEarlyEnd)
                Toggle("Shield distracting apps and websites", isOn: $engine.settings.screenTimeEnforcement)
            }
        }
        .navigationTitle("Screen Breaks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DisciplinePicker: View {
    @Binding var selection: DisciplineLevel

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(DisciplineLevel.allCases) { level in
                Button { selection = level } label: {
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(BreakPalette.accentGradient.opacity(level == selection ? 1 : 0.52))
                            Image(systemName: level == .casual ? "forward.end.fill" : level == .balanced ? "timer" : "lock.fill")
                                .font(.title3)
                        }
                        .frame(height: 54)
                        Text(level.title).font(.caption.weight(.semibold))
                        Text(level.caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(level == selection ? BreakPalette.magenta : .clear, lineWidth: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

struct OfficeHoursSettingsView: View {
    @EnvironmentObject private var engine: BreakEngine

    var body: some View {
        Form {
            Section {
                Toggle("Use office hours", isOn: $engine.settings.officeHours.isEnabled)
            } footer: {
                Text("Interval reminders wait outside these hours. Planned breaks still run at their chosen time.")
            }
            if engine.settings.officeHours.isEnabled {
                Section("Schedule") {
                    DatePicker("Starts", selection: officeTimeBinding(isStart: true), displayedComponents: .hourAndMinute)
                    DatePicker("Ends", selection: officeTimeBinding(isStart: false), displayedComponents: .hourAndMinute)
                    WeekdayPicker(selection: $engine.settings.officeHours.weekdays)
                }
            }
        }
        .navigationTitle("Office Hours")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func officeTimeBinding(isStart: Bool) -> Binding<Date> {
        Binding {
            let hour = isStart ? engine.settings.officeHours.startHour : engine.settings.officeHours.endHour
            let minute = isStart ? engine.settings.officeHours.startMinute : engine.settings.officeHours.endMinute
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        } set: { date in
            let hour = Calendar.current.component(.hour, from: date)
            let minute = Calendar.current.component(.minute, from: date)
            if isStart {
                engine.settings.officeHours.startHour = hour
                engine.settings.officeHours.startMinute = minute
            } else {
                engine.settings.officeHours.endHour = hour
                engine.settings.officeHours.endMinute = minute
            }
        }
    }
}

struct PlannedBreakEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlannedBreak
    let onSave: (PlannedBreak) -> Void
    let onDelete: (() -> Void)?

    init(item: PlannedBreak, onSave: @escaping (PlannedBreak) -> Void, onDelete: (() -> Void)?) {
        _draft = State(initialValue: item)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $draft.isEnabled)
                TextField("Name", text: $draft.name)
                Picker("Icon", selection: $draft.symbol) {
                    ForEach(["fork.knife", "figure.walk", "cup.and.saucer.fill", "sunset.fill", "figure.mind.and.body", "bed.double.fill"], id: \.self) { symbol in
                        Label(symbol.replacingOccurrences(of: ".fill", with: "").capitalized, systemImage: symbol).tag(symbol)
                    }
                }
            }
            Section("Timing") {
                DatePicker("Starts at", selection: timeBinding, displayedComponents: .hourAndMinute)
                Stepper(value: $draft.duration, in: 60...7200, step: 60) {
                    LabeledContent("Duration", value: draft.duration.compactDuration)
                }
                WeekdayPicker(selection: $draft.weekdays)
            }
            if let onDelete {
                Section {
                    Button("Delete planned break", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Planned Break")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.weekdays.isEmpty)
            }
        }
    }

    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: .now) ?? .now
        } set: { date in
            draft.hour = Calendar.current.component(.hour, from: date)
            draft.minute = Calendar.current.component(.minute, from: date)
        }
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let weekdays = Array(1...7)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Repeat on").font(.subheadline)
            HStack(spacing: 6) {
                ForEach(weekdays, id: \.self) { day in
                    Button {
                        if selection.contains(day) { selection.remove(day) } else { selection.insert(day) }
                    } label: {
                        Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(selection.contains(day) ? BreakPalette.magenta : Color.secondary.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                    .accessibilityAddTraits(selection.contains(day) ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct SettingsGlyph: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct SummaryTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

func timeString(hour: Int, minute: Int) -> String {
    let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    return date.formatted(date: .omitted, time: .shortened)
}

func weekdaySummary(_ days: Set<Int>) -> String {
    if days == Set(1...7) { return "Every day" }
    if days == [2, 3, 4, 5, 6] { return "Weekdays" }
    if days == [1, 7] { return "Weekends" }
    return days.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
}
