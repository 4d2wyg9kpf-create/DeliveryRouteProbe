import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DeviceSharingSettingsLink: View {
    @ObservedObject private var store = DeviceSharingStore.shared
    @State private var show = false
    var body: some View {
        Button { show = true } label: {
            HStack { Label("기기 간 공유", systemImage: "icloud"); Spacer(); Text(store.enabled ? "연결됨" : "설정").foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $show) { DeviceSharingSettingsView() }
    }
}
struct DeviceSharingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DeviceSharingStore.shared
    @State private var showFolder = false
    @State private var pickerError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("같은 iCloud Drive 폴더 연결") {
                    Text("아이폰과 아이패드에서 iCloud Drive의 같은 폴더를 각각 한 번 선택하세요. 현재 키와 목록을 합친 뒤 이후의 변경과 삭제를 공유합니다.")
                    Button(store.enabled ? "공유 폴더 다시 선택" : "공유 폴더 선택") { pickerError = nil; showFolder = true }.disabled(store.isSyncing)
                    if store.enabled { LabeledContent("연결한 폴더", value: store.folderName) }
                }
                Section("공유하는 항목") {
                    Label("티맵·네이버·공공데이터 API 키", systemImage: "key")
                    Label("신규 인허가 제외 주소 목록", systemImage: "minus.circle")
                    Label("배송 거래처 목록", systemImage: "list.bullet.rectangle")
                    Label("API별 사용량과 잔여 횟수", systemImage: "number.circle")
                    Text("현재 배송의 선택·물량과 차량 설정은 기기별로 유지합니다. 선택한 폴더의 공유 파일에는 API 키와 거래처 주소가 포함됩니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("동기화 상태") {
                    if store.isSyncing { HStack { ProgressView(); Text("변경을 확인하고 있습니다.") } }
                    Text(store.message)
                    if let date = store.lastSync { LabeledContent("마지막 확인") { Text(date, style: .time) } }
                    if store.deviceCount > 0 { LabeledContent("연결 기기", value: "\(store.deviceCount)대") }
                    if let error = pickerError ?? store.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
                    Button("지금 동기화") { Task { do { try await store.synchronize() } catch { } } }.disabled(!store.enabled || store.isSyncing)
                    Text("앱을 다시 열 때, 실행 중 15초마다, 변경 후와 API 요청 전에 확인합니다. iCloud 반영에는 시간이 걸릴 수 있습니다. 마지막 잔여 횟수를 여러 기기에서 동시에 사용하면 서버가 제한할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                }
                if store.enabled {
                    Section { Button("이 기기의 공유 연결 해제", role: .destructive) { store.disconnect() }.disabled(store.isSyncing) }
                }
            }
            .navigationTitle("기기 간 공유").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .sheet(isPresented: $showFolder) {
                DeviceSharingFolderPicker { url in
                    showFolder = false
                    Task { do { try await store.connect(url) } catch { pickerError = (error as? DeviceShareError)?.localizedDescription ?? DeviceShareError.unavailable.localizedDescription } }
                }
            }
        }
    }
}
struct DeviceSharingFolderPicker: UIViewControllerRepresentable {
    var selected: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator; picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL) -> Void
        init(selected: @escaping (URL) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { selected(url) }
        }
    }
}
