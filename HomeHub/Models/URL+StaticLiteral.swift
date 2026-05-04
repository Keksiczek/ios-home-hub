import Foundation

extension URL {
    /// Trap-on-failure wrapper for static URL literals (model catalog,
    /// fixtures, sample data). The trap message includes the offending
    /// string so a typo in a hardcoded URL produces a debuggable crash
    /// log rather than a bare `EXC_BREAKPOINT` from `URL(string:)!`.
    ///
    /// Use ONLY for compile-time string literals — never for any value
    /// that originates from user input, network, or persisted state.
    init(static string: StaticString) {
        guard let url = URL(string: "\(string)") else {
            preconditionFailure("Invalid static URL literal: \(string)")
        }
        self = url
    }
}
