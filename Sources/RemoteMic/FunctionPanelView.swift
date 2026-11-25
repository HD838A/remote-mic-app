import AppKit
import SwiftUI

struct FunctionPanelView: View {
    @ObservedObject var controller: FunctionPanelController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: String?

    var body: some View {
        ZStack {
            panelSurface
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .frame(width: controller.panelWidth, height: controller.panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(controller.panelTitle))
    }

    @ViewBuilder
    private var panelSurface: some View {
        if #available(macOS 26.0, *) {
            content
                .frame(width: controller.panelWidth, height: controller.panelHeight)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else {
            ZStack {
                FunctionPanelMaterial()
                content
            }
        }
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.8)
    }

    @ViewBuilder
    private var content: some View {
        if controller.items.isEmpty {
            Text(controller.emptyText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: controller.panelWidth, height: controller.panelHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                            let isSelected = index == controller.selectedIndex
                            FunctionPanelItemView(
                                item: item,
                                isSelected: isSelected,
                                isHovered: hoveredID == item.id,
                                colorScheme: colorScheme
                            )
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    hoveredID = item.id
                                } else if hoveredID == item.id {
                                    hoveredID = nil
                                }
                            }
                            .onTapGesture {
                                controller.click(index: index)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(accessibilityLabel(for: item)))
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
                        }
                    }
                    .padding(.horizontal, 24)
                    .frame(minWidth: controller.panelWidth, alignment: .center)
                }
                .frame(width: controller.panelWidth, height: 122)
                .onChange(of: controller.selectedIndex) { _, newValue in
                    guard controller.items.indices.contains(newValue) else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        proxy.scrollTo(controller.items[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func accessibilityLabel(for item: FunctionPanelItem) -> String {
        guard let reason = item.unavailableReasonText else { return item.title }
        return item.title + ", " + reason
    }
}

private struct FunctionPanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .popover
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}

private struct FunctionPanelItemView: View {
    let item: FunctionPanelItem
    let isSelected: Bool
    let isHovered: Bool
    let colorScheme: ColorScheme

    /// v4 的选中色是语义蓝，不跟随系统强调色；SayAll 的其他设置仍用强调色。
    private var accent: Color { Color(nsColor: .systemBlue) }

    private var tileBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.white.opacity(0.72)
    }

    private var tileBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var warningColor: Color {
        colorScheme == .dark
            ? Color(red: 1.0, green: 0.7, blue: 0.25)
            : Color(red: 0.76, green: 0.42, blue: 0)
    }

    private var warningBorder: Color {
        colorScheme == .dark ? Color.black.opacity(0.8) : Color.white.opacity(0.9)
    }

    private var selectionFill: Color {
        accent.opacity(colorScheme == .dark ? 0.22 : 0.12)
    }

    private var selectionBorder: Color {
        accent.opacity(colorScheme == .dark ? 0.55 : 0.45)
    }

    private var hoverFill: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.05)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        isSelected
                            ? selectionFill
                            : (isHovered ? hoverFill : Color.clear)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(
                                isSelected ? selectionBorder : Color.clear,
                                lineWidth: 1.5
                            )
                    }
                    .frame(width: 96, height: 96)

                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(tileBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(tileBorder, lineWidth: 1)
                        }
                    Image(systemName: item.systemImage)
                        .font(.system(size: 38, weight: .regular))
                        .foregroundStyle(.primary)
                }
                .frame(width: 84, height: 84)
                .opacity(item.isAvailable ? (isSelected ? 1 : 0.84) : 0.36)

                if !item.isAvailable {
                    Circle()
                        .fill(warningColor)
                        .frame(width: 10, height: 10)
                        .overlay {
                            Circle().strokeBorder(warningBorder, lineWidth: 2)
                        }
                        .offset(x: 37, y: -37)
                }
            }
            .frame(width: 96, height: 96)

            Text(item.title)
                .font(.system(
                    size: isSelected ? 15 : 14,
                    weight: isSelected ? .semibold : .medium
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 96)
        }
        .frame(width: 96)
    }
}
