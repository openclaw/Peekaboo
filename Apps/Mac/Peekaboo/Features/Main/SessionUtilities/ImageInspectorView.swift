import AppKit
import SwiftUI

// MARK: - Image Inspector View

struct ImageInspectorView: View {
    let image: NSImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoomLevel: CGFloat = 1.0
    @State private var imageOffset = CGSize.zero
    @State private var showPixelGrid = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Image Inspector")
                    .font(.headline)

                Spacer()

                Text("\(Int(self.image.size.width))×\(Int(self.image.size.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Done") {
                    self.dismiss()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Image viewer
            GeometryReader { geometry in
                Image(nsImage: self.image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(self.zoomLevel)
                    .offset(self.imageOffset)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.black)
                    .onTapGesture(count: 2) {
                        withAnimation {
                            self.zoomLevel = self.zoomLevel == 1.0 ? 2.0 : 1.0
                            self.imageOffset = .zero
                        }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                self.imageOffset = value.translation
                            })
            }

            // Controls
            HStack {
                Button(action: { self.zoomLevel = max(0.25, self.zoomLevel - 0.25) }, label: {
                    Image(systemName: "minus.magnifyingglass")
                })

                Slider(value: self.$zoomLevel, in: 0.25...4.0)
                    .frame(width: 200)

                Button(action: { self.zoomLevel = min(4.0, self.zoomLevel + 0.25) }, label: {
                    Image(systemName: "plus.magnifyingglass")
                })

                Divider()
                    .frame(height: 20)

                Toggle("Pixel Grid", isOn: self.$showPixelGrid)
                    .toggleStyle(.checkbox)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 600, idealWidth: 800, minHeight: 400, idealHeight: 600)
    }
}
