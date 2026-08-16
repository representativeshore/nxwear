import Foundation

enum Fmt {
    /// «3 ч 22 мин», «48 мин».
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes) мин" }
        if minutes == 0 { return "\(hours) ч" }
        return "\(hours) ч \(minutes) мин"
    }

    /// «04:45».
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// «12 августа», «12 августа 2025» для прошлых лет.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        let sameYear = Calendar.current.component(.year, from: date)
            == Calendar.current.component(.year, from: Date())
        f.dateFormat = sameYear ? "d MMMM" : "d MMMM yyyy"
        return f.string(from: date)
    }
    static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    /// «пн», «вт» — подписи под столбиками недели.
    static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    static func weekdayShort(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEEEE"
        return f.string(from: date)
    }

    /// «6,4 тыс» — чтобы подписи над столбиками не были простынёй цифр.
    static func compact(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        let thousands = Double(value) / 1000
        return String(format: "%.1f тыс", thousands)
            .replacingOccurrences(of: ".", with: ",")
    }
}
