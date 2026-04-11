import Foundation

struct CalculatorSkill: Skill {
    let name = "Calculator"
    let description = "Evaluates basic mathematical expressions (e.g. '25 * 4 + 10'). Use this to ensure math accuracy. Do not use variables."
    
    func execute(input: String) async throws -> String {
        // Sanitize input to only math characters to prevent injection issues in NSExpression
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^() ")
        let cleanInput = String(input.unicodeScalars.filter { allowed.contains($0) })
        
        guard !cleanInput.isEmpty else {
            return "Error: No valid math expression provided."
        }
        
        let expression = NSExpression(format: cleanInput)
        guard let result = expression.expressionValue(with: nil, context: nil) as? NSNumber else {
            return "Error: Could not compute result for '\(cleanInput)'."
        }
        
        // Format to string safely max 4 decimals
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.usesGroupingSeparator = false
        
        return formatter.string(from: result) ?? result.stringValue
    }
}
