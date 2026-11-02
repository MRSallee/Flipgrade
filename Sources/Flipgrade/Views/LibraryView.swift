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
        VStack(spacing: FlipgradeFont.stackSpacing) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.white)
            Text(session.statusMessage)
                .font(FlipgradeFont.ui)
                .lineSpacing(FlipgradeFont.lineSpacing)
                .foregroundStyle(.white)
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
                .clipped()

            VStack(alignment: .leading, spacing: FlipgradeFont.stackSpacing) {
                Text(record.displayName)
                    .font(FlipgradeFont.folder)
                    .lineSpacing(FlipgradeFont.folderLineSpacing)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(record.subtitlePhotos)
                    .font(FlipgradeFont.ui)
                    .lineSpacing(FlipgradeFont.lineSpacing)
                    .foregroundStyle(.white)

                Text(record.subtitleEdited)
                    .font(FlipgradeFont.ui)
                    .lineSpacing(FlipgradeFont.lineSpacing)
                    .foregroundStyle(.white)
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
                Rectangle()
                    .fill(Color(white: 0.14))
                Image(systemName: "photo")
                    .font(.system(size: FlipgradeFont.folderSize, weight: .regular))
                    .foregroundStyle(.white)
            }
        }
    }
}
