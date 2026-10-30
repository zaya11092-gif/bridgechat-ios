import Foundation
import CoreLocation
import EventKit
import UIKit

// MARK: - Location (one-shot, when-in-use permission)

final class LocationOneShot: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<String, Never>?
    private var denied = false

    func current() async -> String {
        denied = false
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            return "location unavailable (permission denied in Settings)"
        }
        return await withCheckedContinuation { cont in
            continuation = cont
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        continuation?.resume(returning: String(format: "%.5f, %.5f (±%.0f m)", loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy))
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: "location unavailable (\(error.localizedDescription))")
        continuation = nil
    }
}

// MARK: - Calendar (next 7 days, EventKit with permission)

enum CalendarReader {
    static func nextWeek() async -> String {
        let store = EKEventStore()
        do {
            if #available(iOS 17.0, *) {
                let granted = try await store.requestFullAccessToEvents()
                guard granted else { return "calendar access denied" }
            } else {
                let granted = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, Error>) in
                    store.requestAccess(to: .event) { ok, err in
                        if let err { c.resume(throwing: err) } else { c.resume(returning: ok) }
                    }
                }
                guard granted else { return "calendar access denied" }
            }
        } catch {
            return "calendar unavailable (\(error.localizedDescription))"
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 7, to: start) else { return "" }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "no events in the next 7 days" }
        let df = DateFormatter()
        df.dateFormat = "EEE dd MMM HH:mm"
        return events.prefix(40).map { e in
            let title = e.title ?? "(untitled)"
            return "\(df.string(from: e.startDate)) - \(title)"
        }.joined(separator: "\n")
    }
}

// MARK: - Image helpers (downscale to keep vision payloads small)

enum ImageKit {
    static func downscale(_ image: UIImage, maxSide: CGFloat = 1024) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxSide, largest > 0 else { return image }
        let scale = maxSide / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    static func toDataURL(_ image: UIImage) -> String? {
        guard let jpeg = downscale(image).jpegData(compressionQuality: 0.72) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}
