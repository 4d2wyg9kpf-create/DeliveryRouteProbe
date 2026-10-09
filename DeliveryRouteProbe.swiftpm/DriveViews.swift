import SwiftUI

struct DriveRouteSummary: View {
    let route: DriveRoute
    let arrived: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(route.destinationName).font(.title3).bold()
            if let arrival = route.arrivalMinute {
                Text("\(arrived ? "실제 도착" : "저장된 이동시간 기준 도착 예상") \(PlannerClock.text(arrival))")
            }
            Text("등록 이동시간 \(route.minutes)분" + (route.source == "demo" ? " · 가상 예제" : "")).font(.caption)
            if !route.curbName.isEmpty { Label("하역 위치: " + route.curbName, systemImage: "truck.box") }
            if !route.entranceName.isEmpty { Text("가게 입구: " + route.entranceName).font(.caption) }
            if !route.note.isEmpty { Text(route.note) }
            if !route.accessNote.isEmpty { Text(route.accessNote) }
            if !route.arrivalWindowsText.isEmpty { Text("허용 시간: " + route.arrivalWindowsText).font(.caption) }
            if !route.avoidWindowsText.isEmpty { Text("피할 시간: " + route.avoidWindowsText).font(.caption) }
            if route.roadConditionsEnabled {
                Text(route.directionValidated ? "등록한 출발·도착 방향 확인됨" : "출발·도착 방향 미확인").font(.caption)
                if let height = route.heightMM { Text("등록 경로 높이 기준 \(height)mm").font(.caption) }
                if let fare = route.class1TollWon { Text("등록 경로 1종 통행료 \(fare)원").font(.caption) }
            }
            NavigationLink("저장된 교차로 안내·정체 정보") { DriveDetailView(route: route) }
        }
    }
}

private struct DriveDetailView: View {
    let route: DriveRoute
    var body: some View {
        List {
            Section {
                Text(route.destinationName).bold()
                if !route.routeLabel.isEmpty { Text(route.routeLabel) }
                if let time = route.capturedAt { Text("읽은 시각: " + time).font(.caption) }
                Text("저장 당시 네이버 화면의 안내입니다. GPS에 따른 현재 위치·음성 안내와 실시간 정체 자동 갱신은 제공하지 않습니다.").font(.caption).foregroundColor(.secondary)
            }
            Section("저장된 도로별 정체") {
                if route.sections.isEmpty { Text("저장된 도로별 정보가 없습니다.").foregroundColor(.secondary) }
                ForEach(Array(route.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading) {
                        Text(section.road)
                        Text([section.congestion, section.distanceText].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption)
                    }
                }
            }
            Section("상세 이동 안내") {
                if route.guides.isEmpty { Text("이 경로에 연결된 상세 안내가 없습니다.").foregroundColor(.secondary) }
                ForEach(route.guides) { guide in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(guide.index + 1). \(guide.type)").font(.caption).foregroundColor(.secondary)
                        Text(guide.instruction)
                        if !guide.distanceText.isEmpty { Text(guide.distanceText).font(.caption) }
                    }
                }
            }
        }.navigationTitle("등록 경로 상세")
    }
}

struct DriveScheduleSection: View {
    let drive: DriveStatus
    let plan: DeliveryPlan
    var body: some View {
        Section(drive.scheduleFresh ? "남은 배송 일정" : "이전 계산의 참고 순서") {
            if !drive.scheduleFresh {
                Text("실제 작업 완료 후 일정을 갱신합니다. 이전 도착 예상시각은 표시하지 않습니다.").font(.caption).foregroundColor(.secondary)
            }
            if let rest = drive.rest {
                Text("\(drive.scheduleFresh ? "예정 휴식" : "이전 계산의 휴식") \(PlannerClock.text(rest.startMinute))~\(PlannerClock.text(rest.endMinute)) · \(plan.name(rest.visitID))")
            }
            ForEach(drive.upcoming) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(row.position). \(plan.name(row.visitID))" + (row.current ? " · 현재 방문" : ""))
                        .fontWeight(row.current ? .bold : .regular)
                    if drive.scheduleFresh {
                        Text("도착 \(PlannerClock.text(row.arrivalMinute)) · 작업완료 \(PlannerClock.text(row.readyMinute))").font(.caption)
                    }
                }
            }
            if let finish = drive.finishMinute { Text("맑은아침농산 복귀 예상 \(PlannerClock.text(finish))").bold() }
        }
    }
}

struct DriveComparisonView: View {
    let comparison: DriveComparison
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(comparison.sameGuides ? "지점·거리·상세 안내 일치" : "등록 경로와 차이 있음").bold()
            if let minutes = comparison.observedMinutes { Text("등록 \(comparison.plannedMinutes)분 · 새로 읽은 값 \(minutes, specifier: "%.1f")분") }
            ForEach(Array(comparison.messages.enumerated()), id: \.offset) { _, message in Text(message).font(.caption) }
            if let date = comparison.observedAt { Text("비교 자료를 읽은 시각: " + date).font(.caption) }
            if !comparison.sourceTimeText.isEmpty { Text(comparison.sourceTimeText).font(.caption) }
            Text("반영하려면 작업 완료 후 ‘네이버 경로·이동시간 갱신’에서 변경할 일정을 미리 계산해 주세요.").font(.caption).foregroundColor(.secondary)
        }
    }
}
