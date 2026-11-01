import AppKit
import SwiftUI

/// Home screen above Flip — recent cull folders (mock: thumb + name + counts + last edited).
struct LibraryView: View {
    @EnvironmentObject private var session: FlipSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            } else if session.recents.folders.isEmpty {
                emptyState
            } else {
                recentList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.85))
            Text(session.statusMessage)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Open Folder…") {
                session.openFolder()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)
        }
    }

    private var recentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(session.recents.folders) { record in
                    Button {
                        session.openRecent(record)
                    } label: {
                        RecentFolderRow(
                            record: record,
                            thumbnail: session.recents.thumbnail(for: record)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from Recents", role: .destructive) {
                            session.recents.remove(record)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct RecentFolderRow: View {
    let record: RecentFolderRecord
    let thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            thumbnailView
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(record.subtitlePhotos)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.45))

                Text(record.subtitleEdited)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.14))
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}
