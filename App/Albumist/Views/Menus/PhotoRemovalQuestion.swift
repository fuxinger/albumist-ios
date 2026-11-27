import SwiftUI
import AlbumistCore

extension View {
    /// "Foto aus diesem Vorschlag entfernen?" for the photo a suggestion's long press asked to
    /// take out (`ProposalPhotosView`, design wave 2, DS-06a), asked as "Auswählen" asks for
    /// several. On the suggestion's scroll view, beside that question: iOS 26 anchors a
    /// question to its view, and the photos of a long trip are many screens high (review C of
    /// design wave 2, M1). `remove` takes the photo out once it is confirmed.
    func photoRemovalQuestion(_ photo: Binding<AssetID?>, remove: @escaping @MainActor (AssetID) -> Void) -> some View {
        modifier(PhotoRemovalQuestion(photo: photo, remove: remove))
    }
}

private struct PhotoRemovalQuestion: ViewModifier {
    @Binding var photo: AssetID?
    var remove: @MainActor (AssetID) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Foto aus diesem Vorschlag entfernen?", isPresented: asking, titleVisibility: .visible,
                                presenting: photo) { id in
                Button("Entfernen", role: .destructive) { remove(id) }
            } message: { _ in
                Text("Es kommt nicht in dieses Album. In deiner Mediathek und in anderen Vorschlägen bleibt es.")
            }
    }

    private var asking: Binding<Bool> {
        Binding(get: { photo != nil }, set: { if !$0 { photo = nil } })
    }
}
