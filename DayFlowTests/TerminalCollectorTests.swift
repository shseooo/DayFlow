import Testing
import Foundation
@testable import DayFlow

/// `TerminalCollector` 의 pure logic 검증.
///
/// - `decodeLines(from:)` — invalid UTF-8 byte도 안전하게 처리 (U+FFFD 대체)
/// - `parseZsh / parseBash / parseFish` — 각 셸의 history 형식 파싱
struct TerminalCollectorTests {

    // MARK: - decodeLines (invalid UTF-8 회귀 잡기)

    @Test func decodeValidUtf8SplitsIntoLines() {
        let data = "line1\nline2\nline3".data(using: .utf8)!
        let result = TerminalCollector.decodeLines(from: data)
        #expect(result == ["line1", "line2", "line3"])
    }

    @Test func decodeEmptyDataReturnsEmpty() {
        let result = TerminalCollector.decodeLines(from: Data())
        #expect(result == [])
    }

    /// zsh `INC_APPEND_HISTORY`는 `cmd\n` 형식으로 쓰므로 split 끝에 ""가 따라붙는다.
    /// decodeLines는 trailing empty를 제거해야 prev/cur 비교가 정상 동작.
    @Test func decodeStripsTrailingEmptyLine() {
        let data = "cmd1\ncmd2\ncmd3\n".data(using: .utf8)!
        let result = TerminalCollector.decodeLines(from: data)
        #expect(result == ["cmd1", "cmd2", "cmd3"])
    }

    @Test func decodeKoreanUtf8IsPreserved() {
        let data = "한국어 명령\nls -al".data(using: .utf8)!
        let result = TerminalCollector.decodeLines(from: data)
        #expect(result == ["한국어 명령", "ls -al"])
    }

    /// `.zsh_history` 에 0xFF 같은 invalid UTF-8 byte가 끼어 있어도
    /// 빈 배열로 떨어지지 않고 라인이 보존되어야 한다.
    /// (이전엔 `String(contentsOfFile:encoding: .utf8)` 가 nil 반환 → terminal.jsonl 미생성 버그)
    @Test func decodeInvalidUtf8DoesNotDropLines() {
        var bytes: [UInt8] = Array("first_command\n".utf8)
        bytes.append(0xFF)              // invalid UTF-8 byte
        bytes.append(0xFE)              // invalid UTF-8 byte
        bytes.append(contentsOf: Array("\nsecond_command".utf8))
        let data = Data(bytes)

        let result = TerminalCollector.decodeLines(from: data)
        #expect(result.count == 3)
        #expect(result.first == "first_command")
        #expect(result.last == "second_command")
        // 중간 라인은 U+FFFD를 포함
        #expect(result[1].unicodeScalars.contains("\u{FFFD}"))
    }

    // MARK: - parseZsh

    @Test func parseZshExtendedHistoryStripsMetadata() {
        // `: <epoch>:<duration>;<command>` 형식
        let result = TerminalCollector.parseZsh(": 1778510659:0;echo hello")
        #expect(result == "echo hello")
    }

    @Test func parseZshPlainLineReturnsAsIs() {
        // EXTENDED_HISTORY 안 쓰는 경우
        let result = TerminalCollector.parseZsh("ls -la")
        #expect(result == "ls -la")
    }

    @Test func parseZshEmptyReturnsNil() {
        #expect(TerminalCollector.parseZsh("") == nil)
        #expect(TerminalCollector.parseZsh("   ") == nil)
    }

    @Test func parseZshCommandWithSemicolonsKeepsRest() {
        // 첫 ;만 구분자, 그 이후 ;는 명령의 일부
        let result = TerminalCollector.parseZsh(": 1778510659:0;cmd1; cmd2; cmd3")
        #expect(result == "cmd1; cmd2; cmd3")
    }

    // MARK: - parseBash

    @Test func parseBashIgnoresCommentsAndEmpty() {
        #expect(TerminalCollector.parseBash("# this is a comment") == nil)
        #expect(TerminalCollector.parseBash("") == nil)
        #expect(TerminalCollector.parseBash("   ") == nil)
    }

    @Test func parseBashReturnsCommand() {
        #expect(TerminalCollector.parseBash("ls -la") == "ls -la")
        #expect(TerminalCollector.parseBash("  echo hello  ") == "echo hello")
    }

    // MARK: - parseFish

    @Test func parseFishExtractsCmdLine() {
        let result = TerminalCollector.parseFish("- cmd: echo fish")
        #expect(result == "echo fish")
    }

    @Test func parseFishIgnoresNonCmdLines() {
        #expect(TerminalCollector.parseFish("  when: 1778510659") == nil)
        #expect(TerminalCollector.parseFish("") == nil)
        #expect(TerminalCollector.parseFish("- paths:") == nil)
    }
}
