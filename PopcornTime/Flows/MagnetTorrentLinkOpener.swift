//
//  MagnetLinkOpener.swift
//  PopcornTime
//
//  Created by Alexandru Tudose on 19.09.2021.
//  Copyright © 2021 PopcornTime. All rights reserved.
//

import SwiftUI
import PopcornKit

struct MagnetTorrentLinkOpener: ViewModifier {
    let scheme = "magnet"
    
    struct PlayTorrent: Identifiable, Equatable {
        var id: String  { torrent.id }
        var torrent: Torrent
        var movie: Movie
    }
    @State var playTorrent: PlayTorrent?
    
    let anyUrlMatch = Set(arrayLiteral: "*")
    
    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                openUrl(url: url)
            }
            .fullScreenContent(item: $playTorrent, title: "", content: { item in
                TorrentPlayerView(torrent: item.torrent, media: item.movie)
            })
            .handlesExternalEvents(preferring: anyUrlMatch, allowing: anyUrlMatch)
    }
    
    func openUrl(url: URL) {
        if url.scheme == scheme || url.isFileURL {
            let torrentUrl: String
            let id: String
            
            if url.scheme == scheme {
                torrentUrl = url.absoluteString
                id = torrentUrl
            } else {
                var fileUrl = url
                let isiCloudUrl = url.absoluteString.contains("com~apple~CloudDoc")
                if isiCloudUrl {
                    fileUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(url.lastPathComponent)
                    _ = url.startAccessingSecurityScopedResource()
                    try? FileManager.default.copyItem(at: url, to:  fileUrl)
                    url.stopAccessingSecurityScopedResource()
                }
                
                torrentUrl = fileUrl.path
                id = fileUrl.lastPathComponent
            }
            
            let torrent = Torrent(url: torrentUrl)
            let movie = Movie(title: url.lastPathComponent, id: id, torrents: [torrent])
            self.playTorrent = PlayTorrent(torrent: torrent, movie: movie)
        }
    }
}
