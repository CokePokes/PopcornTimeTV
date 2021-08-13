//
//  TabBarView.swift
//  PopcornTimetvOS SwiftUI
//
//  Created by Alexandru Tudose on 19.06.2021.
//  Copyright © 2021 PopcornTime. All rights reserved.
//

import SwiftUI

struct TabBarView: View {
    var body: some View {
        TabView {
            MoviesView()
                .tabItem {
                    Text("Movies")
                }
            ShowsView()
                .tabItem {
                    Text("Shows")
                }
            WatchlistView()
                .tabItem {
                    Text("Watchlist")
                }
            #if os(tvOS)
            SearchView()
                .tabItem {
                    Text("🔍")
                }
            #endif
            DownloadsView()
                .tabItem {
                    Text("Downloads")
                }
            #if os(tvOS) || os(iOS)
            SettingsView()
                .tabItem {
                    Text("Settings")
                }
            #endif
            
        }.ignoresSafeArea()
    }
}

struct TabBarView_Previews: PreviewProvider {
    static var previews: some View {
        TabBarView()
    }
}
