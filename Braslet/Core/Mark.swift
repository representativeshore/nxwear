import Foundation

/// Метка события: время, по возможности место и снимок витальных «в момент».
///
/// Ставится жестом встряхивания — отметить сигарету, симптом, перебой, что
/// угодно, не доставая телефон. Витальные берём последние известные (свежий
/// замер занял бы минуту и потерял бы смысл «в моменте»).
struct Mark: Identifiable, Codable, Hashable {
    let id: UUID
    let time: Date
    var latitude: Double?
    var longitude: Double?
    var pulse: Int?
    var oxygen: Int?
    var hrv: Int?
    var temperature: Double?

    init(id: UUID = UUID(), time: Date,
         latitude: Double? = nil, longitude: Double? = nil,
         pulse: Int? = nil, oxygen: Int? = nil,
         hrv: Int? = nil, temperature: Double? = nil) {
        self.id = id
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.pulse = pulse
        self.oxygen = oxygen
        self.hrv = hrv
        self.temperature = temperature
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }
}
