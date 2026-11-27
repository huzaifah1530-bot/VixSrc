import SwiftUI

/// One season's segments, plus what Vela found in it from other seasons.
/// A suggestion opens the recorder at the spot it was found, so it can be
/// checked, adjusted and saved; nothing is used until then.
struct SeasonSegmentsView: View {
    let context: TitleContext
    let season: Int

    @Environment(AppStore.self) private var store
    @State private var recorder: RecorderRequest?

    private var skipping: SkipSettings { store.titleSettings[context.key]?.skipping ?? SkipSettings() }
    private var segments: [RecordedSegment] { skipping.segments(season: season) }
    private var suggestions: [SegmentSuggestion] { skipping.suggestions(season: season) }
    private var finder: SeasonSuggestionFinder { .shared }

    var body: some View {
        Form {
            Section {
                if segments.isEmpty {
                    Text("No segments for this season yet.").foregroundStyle(.secondary)
                }
                ForEach(segments) { segment in
                    NavigationLink {
                        SegmentDetailView(context: context, segmentID: segment.id) {
                            recorder = RecorderRequest(replacing: segment.id, season: season)
                        }
                    } label: {
                        SegmentRow(segment: segment, manager: context.playerManager)
                    }
                }
                Button {
                    recorder = RecorderRequest(replacing: nil, season: season)
                } label: {
                    Label(segments.isEmpty ? "Record a Segment" : "Record Another Segment", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Season \(season)")
            } footer: {
                Text("Used for every episode of season \(season).")
            }

            if !suggestions.isEmpty || finder.isScanning(titleKey: context.key, season: season) {
                Section {
                    if finder.isScanning(titleKey: context.key, season: season) {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking in this season…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(suggestions) { suggestion in
                        Button {
                            recorder = RecorderRequest(replacing: nil, season: season, suggestion: suggestion)
                        } label: {
                            SuggestionRow(suggestion: suggestion)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.removeSegmentSuggestion(suggestion.id, titleKey: context.key)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeSegmentSuggestion(suggestion.id, titleKey: context.key)
                            } label: {
                                Label("Delete Suggestion", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Suggested")
                } footer: {
                    Text("Found from segments in other seasons. Tap one to check it, adjust where it starts and ends, and save it. Swipe to delete.")
                }
            }

            if otherSeasonSegments.count > 0 {
                Section {
                    Button("Look for Other Seasons' Segments Here") { lookHere() }
                        .disabled(finder.isScanning(titleKey: context.key, season: season))
                } footer: {
                    Text("Searches this season's first episodes for the segments set up in other seasons.")
                }
            }
        }
        .navigationTitle("Season \(season)")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $recorder) { request in
            SegmentRecorderView(context: context, request: request) { segment in
                RecordedSegmentSaver.save(segment, request: request, context: context, store: store)
            }
        }
    }

    /// Segments from other seasons whose name this season doesn't have.
    private var otherSeasonSegments: [(RecordedSegment, Int)] {
        let names = Set(segments.map { $0.name.lowercased() } + suggestions.map { $0.name.lowercased() })
        var seen = Set<String>()
        return context.seasons.filter { $0 != season }.flatMap { other in
            skipping.segments(season: other).map { ($0, other) }
        }.filter { pair in
            let name = pair.0.name.lowercased()
            return !names.contains(name) && seen.insert(name).inserted
        }
    }

    private func lookHere() {
        for (segment, from) in otherSeasonSegments {
            finder.findOthers(for: segment, from: from, only: season, context: context, store: store)
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: SegmentSuggestion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.buttonTitle).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text("\(suggestion.episodeLabel) at \(clockString(suggestion.start)) · \(durationString(suggestion.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Check").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens it to check and save")
    }
}

extension EpisodeRef {
    /// An episode from a progress key such as `tv:1399:2:1`.
    static func fromProgressKey(_ key: String, label: String) -> EpisodeRef? {
        let parts = key.split(separator: ":")
        guard parts.count >= 4, let season = Int(parts[parts.count - 2]), let number = Int(parts[parts.count - 1]) else { return nil }
        return EpisodeRef(id: key, label: label, title: nil, season: season, number: number)
    }
}
