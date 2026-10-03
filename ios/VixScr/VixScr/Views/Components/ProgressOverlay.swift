import SwiftUI

/// Visual progress indicator for media cards showing watch progress percentage
struct ProgressOverlay: View {
    let progress: Double // 0.0 to 1.0
    
    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer()
                
                Rectangle()
                    .fill(Color.blue.opacity(0.9))
                    .frame(height: 3)
                    .frame(width: geometry.size.width * progress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Timestamp badge showing when content was last watched
struct TimestampBadge: View {
    let lastWatched: Date
    
    var body: some View {
        Text(timeAgoString)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white.opacity(0.85))
    }
    
    private var timeAgoString: String {
        let now = Date()
        let interval = now.timeIntervalSince(lastWatched)
        
        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)
        
        if days > 0 {
            return "\(days)d ago"
        } else if hours > 0 {
            return "\(hours)h ago"
        } else if minutes > 0 {
            return "\(minutes)m ago"
        } else {
            return "Just now"
        }
    }
}

/// Combined progress bar and percentage badge for cards
struct WatchProgressIndicator: View {
    let progress: Double // 0.0 to 1.0
    let showPercentage: Bool
    
    init(progress: Double, showPercentage: Bool = false) {
        self.progress = progress
        self.showPercentage = showPercentage
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if showPercentage {
                HStack {
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)
                        .padding(.trailing, 8)
                }
            }
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 3)
                    
                    // Progress fill
                    Rectangle()
                        .fill(Color.blue.opacity(0.9))
                        .frame(width: geometry.size.width * progress, height: 3)
                }
            }
            .frame(height: 3)
        }
    }
}
