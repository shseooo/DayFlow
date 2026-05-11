import Foundation

/// SwiftUI environment(`.locale`) 가 닿지 않는 영역 (NSAlert, ScheduleService statusMessage 등)에서
/// 사용자 `AppSettings.uiLanguage` 에 맞는 문자열을 lookup 한다.
///
/// xcstrings 컴파일 결과: 빌드된 .app 안에 `Contents/Resources/{locale}.lproj/Localizable.strings` 가
/// 자동 생성된다. 그 lproj 번들에서 직접 lookup.
enum L10n {
    /// 사용자가 선택한 UI 언어의 Bundle.
    /// system 모드면 Bundle.main의 preferredLocalization 따름.
    static func bundle() -> Bundle {
        let preferred = AppSettings.load().uiLanguage.locale?.identifier
            ?? Bundle.main.preferredLocalizations.first
        guard let id = preferred,
              let path = Bundle.main.path(forResource: id, ofType: "lproj"),
              let langBundle = Bundle(path: path) else {
            return .main
        }
        return langBundle
    }

    /// 키 lookup. args가 있으면 `String(format:)` 적용.
    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = bundle().localizedString(forKey: key, value: key, table: nil)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: nil, arguments: args)
    }
}
