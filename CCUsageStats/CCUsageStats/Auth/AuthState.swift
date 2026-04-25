import Foundation

enum AuthState: Equatable {
    case unknown
    case ok
    case invalidToken
    case notSubscriber
    case offline
}
