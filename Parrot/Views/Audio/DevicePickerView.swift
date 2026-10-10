import SwiftUI

/// The input device picker (ui 2.6): "System default" plus each connected
/// device with a check on the current choice, a star to mark a priority
/// device, a minus to hide a device, and a Hidden list with a plus to
/// restore one. Embedded in the Sound tab; the recorder can show it in a
/// popover and pass `onPick` to close it. [AUD]
struct DevicePickerView: View {
    let devices: AudioDeviceService
    /// Called after a pick.
    var onPick: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Microphones")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            DevicePickerRow(
                title: "System default",
                detail: devices.systemDefaultDevice?.name,
                systemImage: "gearshape",
                isSelected: devices.followsSystemDefault,
                pick: {
                    devices.useSystemDefault()
                    onPick()
                }
            )

            ForEach(devices.selectableDevices) { device in
                DevicePickerRow(
                    title: device.name,
                    detail: nil,
                    systemImage: device.isBuiltInMic ? "laptopcomputer" : "mic",
                    isSelected: devices.pinnedUID == device.uid,
                    pick: {
                        devices.select(device)
                        onPick()
                    },
                    trailing: {
                        Button {
                            devices.togglePriority(device)
                        } label: {
                            Image(systemName: devices.isPriority(device) ? "star.fill" : "star")
                        }
                        .help("Priority: select this microphone as soon as it connects")
                        Button {
                            devices.exclude(device)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .help("Hide this microphone")
                    }
                )
            }

            if let active = devices.activeDevice, !isChosen(active) {
                Text("Using \(active.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            if devices.resolution.needsLidWarning {
                Label(
                    "Your MacBook lid is closed. The built-in microphone won't work in clamshell mode.",
                    systemImage: "laptopcomputer.trianglebadge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }

            if !devices.hiddenDevices.isEmpty {
                Text("Hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                ForEach(devices.hiddenDevices) { hidden in
                    HStack {
                        Text(hidden.name)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            devices.restore(hidden)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Show this microphone again")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    /// The row with the check is the device in use.
    private func isChosen(_ device: AudioDevice) -> Bool {
        if devices.followsSystemDefault {
            return device.uid == devices.systemDefaultDevice?.uid
        }
        return device.uid == devices.pinnedUID
    }
}

/// One picker row: the whole row picks; trailing buttons act on the device.
private struct DevicePickerRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let systemImage: String
    let isSelected: Bool
    let pick: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: pick) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 12)
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(title)
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            trailing()
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

extension DevicePickerRow where Trailing == EmptyView {
    init(title: String, detail: String?, systemImage: String, isSelected: Bool, pick: @escaping () -> Void) {
        self.init(title: title, detail: detail, systemImage: systemImage, isSelected: isSelected, pick: pick, trailing: { EmptyView() })
    }
}
