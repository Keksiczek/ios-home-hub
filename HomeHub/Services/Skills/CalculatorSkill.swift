import Foundation

struct CalculatorSkill: Skill {
    let name = "Calculator"
    let description = "Evaluates basic mathematical expressions (e.g. '25 * 4 + 10'). Use this to ensure math accuracy. Do not use variables."

    /// Characters that may legitimately appear in a math expression
    /// once whitespace is stripped. `NSExpression` accepts more, but
    /// constraining the alphabet up front lets us reject malformed
    /// model output (Python snippets, JSON blobs, prose) before
    /// `NSExpression(format:)` gets a chance to throw an ObjCException
    /// that Swift's `try` can't catch — that exact crash path landed
    /// in the field when a model emitted
    /// `{ "input": "x = 0; while x < 10: x += 1; print(x)" }`.
    private static let allowedMathChars: CharacterSet = {
        var set = CharacterSet(charactersIn: "0123456789.+-*/^()% ")
        return set
    }()

    func execute(input: String) async throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "Error: No valid math expression provided."
        }

        // Reject if the model included anything outside the math
        // alphabet. Stripping silently (the previous behaviour) turned
        // "x = 0; while x < 10: x += 1; print(x)" into "  0   10  +  1   ()"
        // which then crashed `NSExpression(format:)` with an uncaught
        // NSException. Returning a structured error gives the model a
        // chance to retry with a clean expression on the next turn.
        let invalid = raw.unicodeScalars.first { !Self.allowedMathChars.contains($0) }
        if let bad = invalid {
            return "Error: '\(input)' is not a plain math expression (contains '\(Character(bad))'). Use only numbers and + - * / ^ ( )."
        }

        // After this point every scalar is from the allowed set. Still
        // do a few well-formedness checks so we don't hand NSExpression
        // a string it would choke on.
        let cleaned = raw

        // Must contain at least one digit — protects against inputs
        // like "()" or "+-" that pass the alphabet check but aren't
        // arithmetic.
        guard cleaned.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else {
            return "Error: '\(input)' has no numbers to evaluate."
        }

        // Balanced parentheses. Imbalance is a parse failure in
        // NSExpression, and the failure mode is again an uncaught
        // ObjCException; cheaper to detect ourselves.
        var depth = 0
        for ch in cleaned {
            if ch == "(" { depth += 1 }
            else if ch == ")" {
                depth -= 1
                if depth < 0 { break }
            }
        }
        guard depth == 0 else {
            return "Error: '\(input)' has mismatched parentheses."
        }

        // Cap length so a malicious / runaway prompt can't pin the
        // CPU on a giant expression. 256 characters is generous for
        // any legitimate calculator use.
        guard cleaned.count <= 256 else {
            return "Error: expression is too long (max 256 characters)."
        }

        // NSExpression treats '^' as bitwise XOR, not exponentiation.
        // Rewrite ' a ^ b ' into ' a ** b ' so a user-typed power
        // expression yields the intuitive result. (Bare '**' would
        // also work, but '^' is what people type.)
        let normalized = cleaned.replacingOccurrences(of: "^", with: "**")

        let expression = NSExpression(format: normalized)
        guard let result = expression.expressionValue(with: nil, context: nil) as? NSNumber else {
            return "Error: Could not compute result for '\(input)'."
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.usesGroupingSeparator = false

        return formatter.string(from: result) ?? result.stringValue
    }
}
