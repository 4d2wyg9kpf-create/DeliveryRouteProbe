import SwiftUI
import MapKit

struct CoordinateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let original: TMapCoordinate?
    let onSave: (TMapCoordinate) throws -> Void
    let onReset: (() throws -> Void)?
    @State private var coordinate: TMapCoordinate
    @State private var latitude: String
    @State private var longitude: String
    @State private var satellite = false
    @State private var error: String?
    init(title: String, coordinate: TMapCoordinate?, original: TMapCoordinate? = nil,
         onReset: (() throws -> Void)? = nil, onSave: @escaping (TMapCoordinate) throws -> Void) {
        self.title = title; self.original = original; self.onSave = onSave; self.onReset = onReset
        let value = coordinate ?? TMapCoordinate(longitude: 127.3845, latitude: 36.3504)
        _coordinate = State(initialValue: value)
        _latitude = State(initialValue: String(format: "%.8f", value.latitude))
        _longitude = State(initialValue: String(format: "%.8f", value.longitude))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("지도를 길게 누르거나 표식을 끌어서 위치를 지정하세요.").font(.caption).padding(.horizontal)
                EditableCoordinateMap(coordinate: $coordinate, satellite: satellite).frame(minHeight: 250)
                Form {
                    Toggle("위성 지도", isOn: $satellite)
                    NativeTextField("위도", text: $latitude, keyboard: .decimalPad)
                    NativeTextField("경도", text: $longitude, keyboard: .decimalPad)
                    Button("입력한 좌표로 표식 이동") {
                        guard let lat = Double(latitude), let lon = Double(longitude) else { error = "좌표를 숫자로 입력하세요."; return }
                        let value = TMapCoordinate(longitude: lon, latitude: lat)
                        guard SiteTargetStore.valid(value) else { error = "국내 위도·경도 범위를 확인하세요."; return }
                        coordinate = value; error = nil
                    }
                    if let original { Text("원본: \(original.latitude, specifier: "%.8f"), \(original.longitude, specifier: "%.8f")").font(.caption) }
                    if let onReset { Button("원본 좌표로 복원") { do { try onReset(); dismiss() } catch { self.error = error.localizedDescription } } }
                    if let error { Text(error).foregroundStyle(.red) }
                }.frame(maxHeight: 290)
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("이 좌표 저장") {
                        do { guard SiteTargetStore.valid(coordinate) else { throw DeviceShareError.invalid }; try onSave(coordinate); dismiss() } catch { self.error = error.localizedDescription }
                    } }
                }
                .onChange(of: coordinate) { _, value in
                    latitude = String(format: "%.8f", value.latitude); longitude = String(format: "%.8f", value.longitude)
                }
        }
    }
}
private struct EditableCoordinateMap: UIViewRepresentable {
    @Binding var coordinate: TMapCoordinate
    var satellite: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(); map.delegate = context.coordinator
        let pin = MKPointAnnotation(); pin.coordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        context.coordinator.pin = pin; map.addAnnotation(pin)
        map.setRegion(MKCoordinateRegion(center: pin.coordinate, latitudinalMeters: 500, longitudinalMeters: 500), animated: false)
        map.addGestureRecognizer(UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectPoint(_:))))
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self; map.mapType = satellite ? .hybrid : .standard
        guard let pin = context.coordinator.pin else { return }
        if abs(pin.coordinate.latitude - coordinate.latitude) > 0.000000001 || abs(pin.coordinate.longitude - coordinate.longitude) > 0.000000001 {
            pin.coordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            map.setCenter(pin.coordinate, animated: true)
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: EditableCoordinateMap
        var pin: MKPointAnnotation?
        init(_ parent: EditableCoordinateMap) { self.parent = parent }
        @objc func selectPoint(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MKMapView else { return }
            let selected = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            pin?.coordinate = selected; parent.coordinate = TMapCoordinate(longitude: selected.longitude, latitude: selected.latitude)
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "coordinate"); view.isDraggable = true; return view
        }
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if newState == .ending, let value = view.annotation?.coordinate {
                parent.coordinate = TMapCoordinate(longitude: value.longitude, latitude: value.latitude); view.dragState = .none
            }
        }
    }
}

struct ManualSiteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sites: SiteTargetStore
    @State private var name = ""
    @State private var address = ""
    @State private var showMap = false
    @State private var coordinate: TMapCoordinate?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                NativeTextField("장소·시설 이름", text: $name)
                NativeTextField("주소 · 직접 입력", text: $address)
                Button("지도에서 좌표 지정") { showMap = true }
                if let coordinate { Text("\(coordinate.latitude, specifier: "%.8f"), \(coordinate.longitude, specifier: "%.8f")") }
                Button("평가대상지·시설 목록에 저장") {
                    do { guard let coordinate else { throw PlannerFailure.message("지도에서 좌표를 지정하세요.") }; _ = try sites.saveManual(name: name, address: address, coordinate: coordinate); dismiss() } catch { self.error = error.localizedDescription }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("지도에서 장소 추가").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
                .sheet(isPresented: $showMap) { CoordinateEditorView(title: "좌표 지정", coordinate: coordinate) { coordinate = $0 } }
        }
    }
}
