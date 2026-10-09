# GitHub 표준 Mac에서 서명 전 IPA 만들기

현재 앱 버전은 0.12.0, 빌드 21입니다. iPhone과 iPad를 대상으로 합니다. 앱 소스·Xcode 프로젝트·빌드 설정만 별도 공개 저장소에 올립니다. 실제 거래처·배송 기록·네이버 로그인·티맵 앱키는 기기에서 보관하거나 입력하며 저장소에 올리지 않습니다.

## 빌드

공개 저장소의 main 브랜치에 앱 소스 또는 워크플로를 올리면 **Build unsigned iOS IPA**가 실행됩니다. Actions 화면의 **Run workflow**로도 실행할 수 있습니다. `macos-15` 표준 서버에서 Xcode로 iOS 기기용 arm64 앱을 컴파일하고 `Payload/DeliveryRouteProbe.app` 구조로 IPA를 만듭니다. 서명용 Apple 계정이나 티맵 앱키를 GitHub에 등록할 필요가 없습니다.

컴파일이나 기기용 바이너리 검사에 실패하면 IPA 업로드 단계도 실패합니다. 시뮬레이터용 바이너리와 소스 폴더를 IPA로 포장하지 않습니다. 성공하면 Actions 실행 결과의 **DeliveryRouteProbe-unsigned-ipa**에서 IPA와 SHA256·버전·기기 대상 검사 결과를 받습니다. 빌드 로그는 **DeliveryRouteProbe-build-log**에 있으며 두 자료는 7일 보관합니다.

생성되는 파일은 `DeliveryRouteProbe_0.12.0-21-unsigned.ipa`입니다. 실제 iPad·iPhone에 설치하려면 기존 Sideloadly 등으로 본인 계정의 설치 서명을 진행합니다. 빌드 성공과 실제 기기 실행 확인은 구분합니다.

## 공개 범위

공개할 프로젝트 사본에는 Swift 소스, Xcode 프로젝트, 앱 메타데이터, 세 개의 빌드 스크립트, 워크플로와 이 안내만 포함합니다. 이전 대화·개발 참고자료·경로 판독 이력·진단 로그·개인 계획 파일·기존 M4Download 프로젝트는 포함하지 않습니다. 내장 적재 예제는 가상 계획입니다. 네이버 공개 화면을 판독하는 코드 자체는 포함하며 로그인 데이터는 포함하지 않습니다.

## 현재 실행 상태

이 안내와 워크플로를 준비한 것만으로 IPA가 만들어진 것은 아닙니다. GitHub에 공개 저장소를 만든 뒤 Mac 빌드를 실제로 실행하고 결과를 검사해야 합니다.

근거: [표준 GitHub 서버와 공개 저장소 정책](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [macOS 15 기본 개발 도구](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).
