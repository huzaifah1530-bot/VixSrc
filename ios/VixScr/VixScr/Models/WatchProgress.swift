import Foundation

/// Watch progress tracking for video playback, storing position,
/// duration, and timestamps for resume functionality.
struct WatchProgress: Codable, Identifiable {
    var id: String // Format: "movie:123" or "tv:456:2:3" (type:tmdbId:season:episode)
    var position: Double // Current playback position in seconds
    var duration: Double // Total video duration in seconds
    var lastWatchedAt: Date // Timestamp of last watch
    var completed: Bool // Marked as fully watched
    
    // Computed properties
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(position / duration, 1.0)
    }
    
    var progressPercentage: Int {
        Int(progress * 100)
    }
    
    var shouldResume: Bool {
        // Resume if watched less than 95% and more than 30 seconds in
        progress < 0.95 && position > 30
    }
    
    var timeRemaining: TimeInterval {
        max(0, duration - position)
    }
    
    // Factory methods
    static func forMovie(tmdbId: String, position: Double, duration: Double) -> WatchProgress {
        WatchProgress(
            id: "movie:\(tmdbId)",
            position: position,
            duration: duration,
            lastWatchedAt: Date(),
            completed: position / duration >= 0.95
        )
    }
    
    static func forTVEpisode(tmdbId: String, season: Int, episode: Int, position: Double, duration: Double) -> WatchProgress {
        WatchProgress(
            id: "tv:\(tmdbId):\(season):\(episode)",
            position: position,
            duration: duration,
            lastWatchedAt: Date(),
            completed: position / duration >= 0.95
        )
    }
}

/// Extension for relative time formatting
extension WatchProgress {
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastWatchedAt, relativeTo: Date())
    }
    
    var formattedPosition: String {
        formatTime(position)
    }
    
    var formattedDuration: String {
        formatTime(duration)
    }
    
    var formattedRemaining: String {
        formatTime(timeRemaining)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
