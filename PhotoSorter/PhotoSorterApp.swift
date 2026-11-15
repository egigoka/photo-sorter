import SwiftUI

@main
struct PhotoSorterApp: App {
    @State private var library = Library()

    init() {
        DisplayFace.styleBars()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .tint(.primary)
        }
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if library.hasAccess {
                HomeView()
            } else {
                WelcomeView()
            }
        }
        .animation(.default, value: library.hasAccess)
        .overlay(alignment: .bottom) {
            if let toast = library.toast {
                ToastView(text: toast.text, undo: toast.canUndo ? { library.undo() } : nil)
                    .padding(.horizontal, 24)
                    .besideFold()
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: library.toast)
        .sensoryFeedback(trigger: library.toast) { _, new in new == nil ? nil : .success }
        .task(id: library.toast) {
            guard let toast = library.toast else { return }
            AccessibilityNotification.Announcement(toast.text).post()
            // A banner with Undo stays longer, so there is time to tap it.
            try? await Task.sleep(for: .seconds(toast.canUndo ? 5 : 3))
            if !Task.isCancelled { library.dismissToast() }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { library.message != nil },
            set: { if !$0 { library.message = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.message ?? "")
        }
        .task { await library.checkModels() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refreshAuthorization()
            } else {
                // The app can be closed from here. A running scan saves what it has.
                library.saveProgress()
            }
        }
    }
}
