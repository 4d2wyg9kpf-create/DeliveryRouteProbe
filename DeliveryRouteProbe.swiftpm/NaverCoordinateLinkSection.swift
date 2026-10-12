import SwiftUI

private struct NaverCoordinateWebTarget: Identifiable {
    let id = UUID()
    let target: NaverSharedLink.Target
    let originalURL: String
}

struct NaverCoordinateLinkSection: View {
    @EnvironmentObject private var inputs: NativeInputSession
    let onCoordinate: (TMapCoordinate) -> Void
    var onReadingChanged: (Bool) -> Void = { _ in }
    @State private var link = ""
    @State private var resolving = false
    @State private var task: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var webTarget: NaverCoordinateWebTarget?
    @State private var error: String?
    @State private var message = ""
    private var busy: Bool { resolving || webTarget != nil }

    var body: some View {
        Section("네이버지도 링크로 좌표 수정") {
            NativeTextField("네이버지도 공유 링크 · 공유문 전체도 가능", text: $link,
                            keyboard: .URL, returnKey: .go, onSubmit: applyLink)
                .frame(minHeight: 44).disabled(busy)
            HStack {
                PasteButton(payloadType: String.self) { values in link = values.first ?? "" }
                    .disabled(busy)
                Button(resolving ? "좌표 읽는 중…" : "링크 좌표 적용", action: applyLink)
                    .disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if resolving { ProgressView() }
            Text("공유한 지점의 좌표를 반영한 뒤 저장하세요.").font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: busy) { _, value in onReadingChanged(value) }
        .onChange(of: link) { _, _ in error = nil; message = "" }
        .onDisappear {
            task?.cancel(); task = nil; requestID = nil; resolving = false
            onReadingChanged(false)
        }
        .sheet(item: $webTarget) { value in
            NaverCoordinatePlaceReader(target: value.target, originalURL: value.originalURL) { point in
                onCoordinate(point); message = "링크 좌표를 반영했습니다."
            }
        }
    }

    private func applyLink() {
        inputs.finishEditing()
        guard !busy, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID(), submitted = link
        requestID = token; resolving = true; error = nil; message = ""
        onReadingChanged(true)
        task = Task { @MainActor in
            do {
                let result = try await NaverSharedLinkResolver().resolveCoordinate(submitted)
                guard !Task.isCancelled, requestID == token else { return }
                switch result {
                case .coordinate(let point):
                    onCoordinate(point); message = "링크 좌표를 반영했습니다."
                case .place(let target, let originalURL):
                    webTarget = NaverCoordinateWebTarget(target: target, originalURL: originalURL)
                }
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                self.error = error.localizedDescription
            }
            guard requestID == token else { return }
            task = nil; requestID = nil; resolving = false
            onReadingChanged(webTarget != nil)
        }
    }
}

// Registered-place links without an explicit point use the existing native
// selected-place reader. Do not geocode their labels or import saved lists.
private struct NaverCoordinatePlaceReader: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BrowserModel()
    let target: NaverSharedLink.Target
    let originalURL: String
    let onCoordinate: (TMapCoordinate) -> Void
    @State private var error: String?
    @State private var reading = false
    @State private var polling = true
    @State private var active = true
    @State private var manualTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("공유한 장소를 PC 크기로 열어 좌표를 확인합니다. 가로로 밀어 전체 화면을 볼 수 있습니다.").font(.caption).padding(.horizontal)
                if browser.isLoading || polling || reading { ProgressView() }
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
                Button("이 장소 좌표 다시 읽기") {
                    guard !reading, !polling else { return }
                    reading = true; error = nil
                    manualTask = Task { @MainActor in
                        defer { reading = false; manualTask = nil }
                        do { accept(try await readCoordinate()) }
                        catch { if active && !Task.isCancelled { self.error = error.localizedDescription } }
                    }
                }.disabled(browser.isLoading || polling || reading)
                MapWebView(webView: browser.webView, desktop: true)
            }
            .navigationTitle("네이버지도 좌표 확인").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            .task {
                browser.desktopCanvas = true
                browser.openRecordedRoute(target.url.absoluteString)
                let deadline = Date().addingTimeInterval(30)
                defer { polling = false }
                while active && !Task.isCancelled && Date() < deadline {
                    if !browser.isLoading, let point = try? await readCoordinate() {
                        accept(point); return
                    }
                    do { try await Task.sleep(nanoseconds: 600_000_000) }
                    catch { return }
                }
                if active && !Task.isCancelled {
                    error = "공유한 장소의 좌표를 읽지 못했습니다. 장소 화면이 열린 뒤 다시 읽거나 해당 지점의 공유 링크를 다시 복사해 주세요."
                }
            }
            .onDisappear { active = false; manualTask?.cancel(); browser.webView.stopLoading() }
        }
    }

    private func readCoordinate() async throws -> TMapCoordinate {
        guard case .place(let expectedID) = target.kind else { throw DeviceShareError.invalid }
        let root = try await NaverWebReader.root(browser.webView)
        guard root["placeID"] as? String == expectedID else {
            throw PlannerFailure.message("공유한 장소 화면을 먼저 열어 주세요.")
        }
        let capture = try await NaverWebReader.selected(browser.webView, resolveCoordinate: false, sharedURL: originalURL)
        guard capture.placeID == expectedID, let point = capture.coordinate, SiteTargetStore.valid(point) else {
            throw PlannerFailure.message("공유한 장소의 선택 좌표를 확인하지 못했습니다. 해당 지점을 선택해 공유 링크를 다시 복사해 주세요.")
        }
        return point
    }
    private func accept(_ point: TMapCoordinate) {
        guard active, !Task.isCancelled else { return }
        active = false; onCoordinate(point); dismiss()
    }
}
