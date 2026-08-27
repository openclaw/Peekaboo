import AppKit
import SwiftUI

struct ScrollTestingView: View {
    @EnvironmentObject var actionLogger: ActionLogger
    @State private var scrollPosition: CGPoint = .zero
    @State private var lastGesture = ""
    @State private var magnification: CGFloat = 1.0
    @State private var rotation: Angle = .zero
    @State private var lastVerticalOffset: CGFloat?
    @State private var lastHorizontalOffset: CGFloat?
    @State private var lastNestedInnerOffset: CGFloat?
    @State private var lastNestedOuterOffset: CGFloat?
    @State private var actionValue = 0
    @State private var semanticState = ScrollTestingSemanticState()

    var body: some View {
        VStack(spacing: 20) {
            SectionHeader(title: "Scroll & Gesture Testing", icon: "scroll")

            HStack(spacing: 20) {
                // Vertical scroll
                GroupBox("Vertical Scroll") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(1..<31) { index in
                                    HStack {
                                        Text("Item \(index)")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Spacer()
                                        Image(systemName: "\(index).circle")
                                    }
                                    .padding()
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                                    .id(index)
                                    .onAppear {
                                        if index == 1 || index == 15 || index == 30 {
                                            self.actionLogger.log(.scroll, "Visible item: \(index)")
                                        }
                                    }
                                }
                            }
                            // Measure the *content* offset inside the scroll view's coordinate space.
                            // (Measuring the ScrollView itself always reports 0,0.)
                            .background(ScrollOffsetReader(coordinateSpace: "vertical-scroll-area") { offset in
                                self.logVerticalScrollChange(offset: offset.y)
                            })
                            .background(
                                ScrollAccessibilityConfigurator(
                                    identifier: "vertical-scroll",
                                    label: "Vertical Scroll Area"))
                        }
                        .overlay(
                            AXScrollTargetOverlay(
                                identifier: "vertical-scroll",
                                label: "Vertical Scroll Area"))
                        .padding()
                        .frame(height: 300)
                        .background(Color(NSColor.controlBackgroundColor))
                        .coordinateSpace(name: "vertical-scroll-area")

                        HStack {
                            Button("Top") {
                                withAnimation {
                                    proxy.scrollTo(1, anchor: .top)
                                }
                                self.actionLogger.log(.scroll, "Scrolled to top")
                            }
                            .accessibilityIdentifier("scroll-to-top")

                            Button("Middle") {
                                withAnimation {
                                    proxy.scrollTo(15, anchor: .center)
                                }
                                self.actionLogger.log(.scroll, "Scrolled to middle")
                            }
                            .accessibilityIdentifier("scroll-to-middle")

                            Button("Bottom") {
                                withAnimation {
                                    proxy.scrollTo(30, anchor: .bottom)
                                }
                                self.actionLogger.log(.scroll, "Scrolled to bottom")
                            }
                            .accessibilityIdentifier("scroll-to-bottom")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Horizontal scroll
                GroupBox("Horizontal Scroll") {
                    VStack {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(1..<21) { index in
                                    VStack {
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                        Text("Image \(index)")
                                            .font(.caption)
                                    }
                                    .frame(width: 100, height: 100)
                                    .background(Color.purple.opacity(0.2))
                                    .cornerRadius(8)
                                    .onAppear {
                                        if index == 1 || index == 10 || index == 20 {
                                            self.actionLogger.log(.scroll, "Horizontal item visible: \(index)")
                                        }
                                    }
                                }
                            }
                            // Measure the *content* offset inside the scroll view's coordinate space.
                            .background(ScrollOffsetReader(coordinateSpace: "horizontal-scroll-area") { offset in
                                self.logHorizontalScrollChange(offset: offset.x)
                            })
                            .background(
                                ScrollAccessibilityConfigurator(
                                    identifier: "horizontal-scroll",
                                    label: "Horizontal Scroll Area"))
                        }
                        .overlay(
                            AXScrollTargetOverlay(
                                identifier: "horizontal-scroll",
                                label: "Horizontal Scroll Area"))
                        .padding()
                        .frame(height: 150)
                        .background(Color(NSColor.controlBackgroundColor))
                        .coordinateSpace(name: "horizontal-scroll-area")
                    }
                }
            }

            GroupBox("Accessibility Actions") {
                Stepper("Action value: \(self.actionValue)", value: self.$actionValue, in: -10...10)
                    .accessibilityIdentifier("action-stepper")
                    .accessibilityLabel("Action Stepper")
                    .accessibilityValue(String(self.actionValue))
                    .onChange(of: self.actionValue) { oldValue, newValue in
                        let direction = newValue > oldValue ? "incremented" : "decremented"
                        self.actionLogger.log(
                            .control,
                            "Action stepper \(direction)",
                            details: "Value: \(oldValue) → \(newValue)")
                    }
            }
            .playgroundSemanticWitness(
                .actionStepperValue,
                value: String(self.actionValue))

            // Gesture testing area
            GroupBox("Gesture Testing") {
                HStack(spacing: 20) {
                    // Swipe gestures
                    GestureArea(
                        title: "Swipe Area",
                        color: .green,
                        identifier: "swipe-area")
                    {
                        Image(systemName: "hand.draw")
                            .font(.largeTitle)
                    }
                    .onTapGesture {
                        self.actionLogger.log(.gesture, "Tap on swipe area")
                    }
                    .gesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                let horizontal = abs(value.translation.width)
                                let vertical = abs(value.translation.height)

                                if horizontal > vertical {
                                    let direction = value.translation.width > 0 ? "right" : "left"
                                    self.actionLogger.log(
                                        .gesture,
                                        "Swipe \(direction)",
                                        details: "Distance: \(Int(horizontal))px")
                                } else {
                                    let direction = value.translation.height > 0 ? "down" : "up"
                                    self.actionLogger.log(
                                        .gesture,
                                        "Swipe \(direction)",
                                        details: "Distance: \(Int(vertical))px")
                                }
                            })

                    // Pinch/Zoom
                    GestureArea(
                        title: "Pinch/Zoom",
                        color: .orange,
                        identifier: "pinch-area")
                    {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.largeTitle)
                            .scaleEffect(self.magnification)
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                self.magnification = value
                            }
                            .onEnded { value in
                                self.actionLogger.log(
                                    .gesture,
                                    "Pinch gesture ended",
                                    details: "Scale: \(String(format: "%.2f", value))x")
                                withAnimation {
                                    self.magnification = 1.0
                                }
                            })

                    // Rotation
                    GestureArea(
                        title: "Rotation",
                        color: .blue,
                        identifier: "rotation-area")
                    {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.largeTitle)
                            .rotationEffect(self.rotation)
                    }
                    .gesture(
                        RotationGesture()
                            .onChanged { angle in
                                self.rotation = angle
                            }
                            .onEnded { angle in
                                self.actionLogger.log(
                                    .gesture,
                                    "Rotation gesture ended",
                                    details: "Angle: \(Int(angle.degrees))°")
                                withAnimation {
                                    self.rotation = .zero
                                }
                            })

                    // Long press
                    GestureArea(
                        title: "Long Press",
                        color: .red,
                        identifier: "long-press-area")
                    {
                        Image(systemName: "hand.tap.fill")
                            .font(.largeTitle)
                    }
                    .onLongPressGesture(minimumDuration: 1.0) {
                        self.actionLogger.log(
                            .gesture,
                            "Long press detected",
                            details: "Duration: 1.0s")
                    }
                }
            }

            // Nested scroll views
            GroupBox("Nested Scroll Views") {
                ScrollView {
                    VStack(spacing: 10) {
                        Text("Outer scroll view")
                            .font(.headline)

                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(1..<11) { index in
                                    Text("Inner item \(index)")
                                        .padding(.horizontal)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding()
                            .background(ScrollOffsetReader(coordinateSpace: "nested-inner-scroll-area") { offset in
                                self.logNestedInnerScrollChange(offset: offset.y)
                            })
                            .background(Color.gray.opacity(0.1))
                            .background(
                                ScrollAccessibilityConfigurator(
                                    identifier: "nested-inner-scroll",
                                    label: "Nested Inner Scroll"))
                        }
                        .overlay(
                            AXScrollTargetOverlay(
                                identifier: "nested-inner-scroll",
                                label: "Nested Inner Scroll"))
                        .frame(height: 150)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                        .coordinateSpace(name: "nested-inner-scroll-area")

                        ForEach(1..<6) { index in
                            Text("Outer item \(index)")
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(ScrollOffsetReader(coordinateSpace: "nested-outer-scroll-area") { offset in
                        self.logNestedOuterScrollChange(offset: offset.y)
                    })
                    .background(
                        ScrollAccessibilityConfigurator(
                            identifier: "nested-outer-scroll",
                            label: "Nested Outer Scroll"))
                }
                .overlay(
                    AXScrollTargetOverlay(
                        identifier: "nested-outer-scroll",
                        label: "Nested Outer Scroll"))
                .frame(height: 200)
                .background(Color(NSColor.controlBackgroundColor))
                .coordinateSpace(name: "nested-outer-scroll-area")
            }

            Spacer()
        }
        .padding()
        .playgroundSemanticWitness(
            .verticalScrollOffset,
            value: self.semanticState.verticalScrollOffset)
    }

    private func logVerticalScrollChange(offset: CGFloat) {
        let rounded = (offset * 100).rounded() / 100
        self.semanticState.recordVerticalScrollOffset(rounded)
        if let lastOffset = self.lastVerticalOffset, abs(lastOffset - rounded) < 5 {
            return
        }
        self.lastVerticalOffset = rounded
        self.actionLogger.log(
            .scroll,
            "Vertical scroll offset",
            details: "y=\(Int(rounded))")
    }

    private func logHorizontalScrollChange(offset: CGFloat) {
        let rounded = (offset * 100).rounded() / 100
        if let lastOffset = self.lastHorizontalOffset, abs(lastOffset - rounded) < 5 {
            return
        }
        self.lastHorizontalOffset = rounded
        self.actionLogger.log(
            .scroll,
            "Horizontal scroll offset",
            details: "x=\(Int(rounded))")
    }

    private func logNestedInnerScrollChange(offset: CGFloat) {
        let rounded = (offset * 100).rounded() / 100
        if let lastOffset = self.lastNestedInnerOffset, abs(lastOffset - rounded) < 5 {
            return
        }
        self.lastNestedInnerOffset = rounded
        self.actionLogger.log(
            .scroll,
            "Nested inner scroll offset",
            details: "y=\(Int(rounded))")
    }

    private func logNestedOuterScrollChange(offset: CGFloat) {
        let rounded = (offset * 100).rounded() / 100
        if let lastOffset = self.lastNestedOuterOffset, abs(lastOffset - rounded) < 5 {
            return
        }
        self.lastNestedOuterOffset = rounded
        self.actionLogger.log(
            .scroll,
            "Nested outer scroll offset",
            details: "y=\(Int(rounded))")
    }
}

private struct ScrollOffsetReader: View {
    var coordinateSpace: String
    var onChange: (CGPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: ScrollOffsetPreferenceKey.self,
                    value: proxy.frame(in: .named(self.coordinateSpace)).origin)
        }
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            self.onChange(value)
        }
    }
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero

    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

struct GestureArea: View {
    let title: String
    let color: Color
    let identifier: String
    let content: () -> AnyView

    init(title: String, color: Color, identifier: String, @ViewBuilder content: @escaping () -> some View) {
        self.title = title
        self.color = color
        self.identifier = identifier
        self.content = { AnyView(content()) }
    }

    var body: some View {
        VStack {
            self.content()
            Text(self.title)
                .font(.caption)
                .padding(.top, 5)
        }
        .frame(width: 120, height: 120)
        .background(self.color.opacity(0.2))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(self.color, lineWidth: 2))
        .accessibilityIdentifier(self.identifier)
    }
}

private struct ScrollAccessibilityConfigurator: NSViewRepresentable {
    let identifier: String
    let label: String

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.identifierValue = self.identifier
        view.labelValue = self.label
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.identifierValue = self.identifier
        nsView.labelValue = self.label
        nsView.updateScrollIdentifier()
    }

    final class ConfiguratorView: NSView {
        var identifierValue: String?
        var labelValue: String?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.updateScrollIdentifier() }
        }

        override func layout() {
            super.layout()
            DispatchQueue.main.async { self.updateScrollIdentifier() }
        }

        func updateScrollIdentifier() {
            guard
                let id = self.identifierValue,
                let label = self.labelValue,
                let scrollView = self.enclosingScrollView
            else { return }

            scrollView.setAccessibilityIdentifier(id)
            scrollView.setAccessibilityLabel(label)
            scrollView.setAccessibilityRole(.scrollArea)
            scrollView.setAccessibilityElement(true)
            scrollView.contentView.setAccessibilityIdentifier("\(id)-clip")
            scrollView.documentView?.setAccessibilityIdentifier("\(id)-content")

            NSAccessibility.post(element: scrollView, notification: .layoutChanged)
        }
    }
}

private struct AXScrollTargetOverlay: NSViewRepresentable {
    let identifier: String
    let label: String

    func makeNSView(context: Context) -> ProxyAXView {
        let view = ProxyAXView()
        view.configure(id: self.identifier, label: self.label)
        return view
    }

    func updateNSView(_ nsView: ProxyAXView, context: Context) {
        nsView.configure(id: self.identifier, label: self.label)
    }

    final class ProxyAXView: NSView {
        private var idValue = ""
        private var labelValue = ""

        override var isOpaque: Bool {
            false
        }

        override func draw(_ dirtyRect: NSRect) {
            // transparent overlay
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func configure(id: String, label: String) {
            self.idValue = id
            self.labelValue = label
            self.setAccessibilityElement(true)
            self.setAccessibilityRole(.scrollArea)
            self.setAccessibilityIdentifier(id)
            self.setAccessibilityLabel(label)
        }

        override func accessibilityFrame() -> NSRect {
            guard let window else { return .zero }
            let inWindow = self.convert(self.bounds, to: nil)
            return window.convertToScreen(inWindow)
        }
    }
}
