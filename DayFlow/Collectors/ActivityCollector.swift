import Foundation

/// 데이터 수집기 프로토콜
/// 수집된 활동은 ActivityLogStore를 통해 디스크에 즉시 영속화된다.
protocol ActivityCollector {
    var name: String { get }
    func start()
    func stop()
}
