# GitHub 표준 Mac에서 서명 전 IPA 만들기

현재 앱 버전은 0.12.1, 빌드 22입니다. iPhone과 iPad를 대상으로 합니다. 앱 소스·Xcode 프로젝트·빌드 설정만 별도 공개 저장소에 올립니다. 실제 거래처·배송 기록·네이버 로그인·티맵 앱키는 기기에서 보관하거나 입력하며 저장소에 올리지 않습니다.

## 빌드

공개 저장소의 main 브랜치에 앱 소스 또는 워크플로를 올리면 **Build unsigned iOS IPA**가 실행됩니다. Actions 화면의 **Run workflow**로도 실행할 수 있습니다. `macos-15` 표준 서버에서 Xcode로 iOS 기기용 arm64 앱을 컴파일하고 `Payload/DeliveryRouteProbe.app` 구조로 IPA를 만듭니다. 서명용 Apple 계정이나 티맵 앱키를 GitHub에 등록할 필요가 없습니다.

컴파일이나 기기용 바이너리 검사에 실패하면 IPA 업로드 단계도 실패합니다. 시뮬레이터용 바이너리와 소스 폴더를 IPA로 포장하지 않습니다. 성공하면 Actions 실행 결과의 **DeliveryRouteProbe-unsigned-ipa**에서 IPA와 SHA256·버전·기기 대상 검사 결과를 받습니다. 빌드 로그는 **DeliveryRouteProbe-build-log**에 있으며 두 자료는 7일 보관합니다.

생성되는 파일은 `DeliveryRouteProbe_0.12.1-22-unsigned.ipa`입니다. 실제 iPad·iPhone에 설치하려면 기존 Sideloadly 등으로 본인 계정의 설치 서명을 진행합니다. 빌드 성공과 실제 기기 실행 확인은 구분합니다.

## 개인 서명용 앱 이름

0.12.1부터 `CFBundleName`과 `CFBundleDisplayName`은 `DeliveryRoute`입니다. 이전 IPA에서 기본 표시 이름 ‘배송경로’가 Apple의 `appIdName`으로 전달되어 거절되는 설치 오류가 보고되어, 두 이름을 영문으로 지정했습니다. 홈 화면 이름도 `DeliveryRoute`로 표시되며 앱 내부 한국어 UI는 유지합니다. 앱 식별자 `kr.deliverytools.routeprobe`는 유지했습니다. 패키징 단계에서 두 이름에 한글·특수문자가 들어가면 빌드를 실패시켜 같은 메타데이터가 다시 배포되지 않도록 합니다.

Sideloadly에서 앱 이름 변경 옵션을 사용한다면 영문 이름을 사용해야 합니다. 실제 설치 완료 여부는 새 IPA로 기기에서 확인해야 합니다.

## 공개 범위

공개할 프로젝트 사본에는 Swift 소스, Xcode 프로젝트, 앱 메타데이터, 세 개의 빌드 스크립트, 워크플로와 이 안내만 포함합니다. 이전 대화·개발 참고자료·경로 판독 이력·진단 로그·개인 계획 파일·기존 M4Download 프로젝트는 포함하지 않습니다. 내장 적재 예제는 가상 계획입니다. 네이버 공개 화면을 판독하는 코드 자체는 포함하며 로그인 데이터는 포함하지 않습니다.

## 빌드 확인

2026-10-09 앱 등록 이름을 수정한 Mac 빌드가 성공했습니다. [실행 결과](https://github.com/4d2wyg9kpf-create/DeliveryRouteProbe/actions/runs/37918926395)에서 IPA와 빌드 로그를 확인할 수 있습니다.

- 앱: 0.12.1 / 빌드 22, iPhone·iPad, iOS 18 이상
- Xcode 16.4 / iPhoneOS SDK 18.5로 실제 arm64 기기 앱을 컴파일했습니다.
- IPA: `DeliveryRouteProbe_0.12.1-22-unsigned.ipa` (1,675,467 bytes)
- SHA256: `64df8f003487cbcdef615cb115091fca05cf30c1dec2527418f748b4639e736a`
- 소스 커밋: `ca1324a30d07b1bf8a4c43274e131a28906985e7`

다운로드한 IPA의 ZIP 무결성, 앱 식별자·버전, 실행 파일 권한, arm64 Mach-O의 iOS 기기 대상도 검사했습니다. 실제 iPhone·iPad에서의 실행과 TMAP 실요청은 아직 확인하지 않았습니다.

근거: [표준 GitHub 서버와 공개 저장소 정책](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [macOS 15 기본 개발 도구](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).
