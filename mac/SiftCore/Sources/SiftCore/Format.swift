import Foundation

public enum Format {
    /// "554 KB", "1.4 GB": decimal units, as the Finder shows them.
    public static func size(_ bytes: Int64) -> String {
        var n = Double(bytes)
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if n < 1000 || unit == "TB" {
                if unit == "B" || unit == "KB" { return "\(Int(n.rounded())) \(unit)" }
                return "\((n * 10).rounded() / 10) \(unit)"
            }
            n /= 1000
        }
        return ""
    }

    public static func plural(_ n: Int, _ word: String, _ words: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? word : (words ?? word + "s"))"
    }

    /// "about 3 minutes left", from how long the work so far took.
    public static func timeLeft(spent: TimeInterval, done: Int, total: Int) -> String? {
        guard done > 0, done < total, spent > 5 else { return nil }
        let left = spent * Double(total - done) / Double(done)
        if left < 60 { return "less than a minute left" }
        let minutes = Int((left / 60).rounded())
        if minutes < 60 { return "about \(plural(minutes, "minute")) left" }
        return "about \(plural(Int((left / 3600).rounded()), "hour")) left"
    }
}
