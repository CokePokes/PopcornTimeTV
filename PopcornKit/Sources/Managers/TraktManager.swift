

import ObjectMapper
import Alamofire
import SwiftyJSON
import Foundation

#if os(iOS)
    import SafariServices
    import UIKit
#endif
#if os(tvOS)
    import UIKit
#endif

open class TraktManager: NetworkManager {
    
    
    /// Creates new instance of TraktManager class
    public static let shared = TraktManager()
    
    /// OAuth state parameter added for extra security against cross site forgery.
    fileprivate var state: String!
    
    let client = HttpClient(config: .init(serverURL: Trakt.base, configuration: {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 30
//        configuration.urlCache = nil
//        configuration.requestCachePolicy = .returnCacheDataDontLoad
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpAdditionalHeaders = Trakt.Headers.Default
        return configuration
    }()))
    
    /**
     Scrobbles current video.
     
     - Parameter id:            The imdbId for movies and tvdbId for episodes of the media that is playing.
     - Parameter progress:      The progress of the playing video. Possible values range from 0...1.
     - Parameter type:          The type of the item, either `Episode` or `Movie`.
     - Parameter status:        The status of the item.
     
     - Parameter completion:    Optional completion handler only called if an error is thrown.
     */
    open func scrobble(_ id: String, progress: Float, type: Trakt.MediaType, status: Trakt.WatchedStatus, completion: ((NSError) -> Void)? = nil) {
        guard var credential = traktCredentials() else { return }
        guard progress != 0 else { return removePlaybackProgress(id, type: type) }
        DispatchQueue.global(qos: .background).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    completion?(error)
                }
            }
            let parameters: [String: Any]
            if type == .movies {
                parameters = ["movie": ["ids": ["imdb": id]], "progress": progress * 100.0]
            } else {
                parameters = ["episode": ["ids": ["tvdb": Int(id)!]], "progress": progress * 100.0]
            }
            self.manager.request(Trakt.base + Trakt.scrobble + "/\(status.rawValue)", method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON { response in
                if let error = response.result.error { completion?(error as NSError) }
            }
        }
    }
    
    /**
     Load episode metadata from API.
     
     - Parameter show:          The imdbId or slug for the show.
     - Parameter episodeNumber: The number of the episode in relation to its current season.
     - Parameter seasonNumber:  The season of which the episode is in.
     */
    open func getEpisodeMetadata(_ showId: String, episodeNumber: Int, seasonNumber: Int) async throws -> Episode {
        let path = Trakt.shows + "/\(showId)" + Trakt.seasons + "/\(seasonNumber)" + Trakt.episodes + "/\(episodeNumber)"
        return try await client.request(.get, path: path, parameters: Trakt.extended).responseMapable(context: TraktContext())
    }
    
    /**
     Retrieves users previously watched videos.
     
     - Parameter type:          The type of the item (either movie or episode).
     
     - Parameter completion:    The completion handler for the request containing an array of media objects and an optional error.
     */
    open func getWatched<T: Media>(forMediaOfType type: T.Type, completion:@escaping ([T], NSError?) -> Void) {
        guard var credential = traktCredentials() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    DispatchQueue.global(qos: .background).async(execute: { completion([T](), error) })
                }
            }
            let type = type is Movie.Type ? Trakt.movies : Trakt.episodes
            let queue = DispatchQueue(label: "com.popcorntimetv.popcornkit.response.queue", attributes: .concurrent)
            self.manager.request(Trakt.base + Trakt.sync + Trakt.history + type, parameters: ["extended": "full", "limit": Int.max], headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON(queue: queue, options: .allowFragments) { response in
                guard let value = response.result.value else { completion([T](), response.result.error as NSError?); return }
                let responseObject = JSON(value)
                var watchedlist = [T]()
                let group = DispatchGroup()
                for (_, item) in responseObject {
                    guard let type = item["type"].string,
                        let media = Mapper<T>(context: TraktContext()).map(JSONObject: item[type].dictionaryObject)
                        else { continue }
                    group.enter()
                    guard var episode = media as? Episode, let show = Mapper<Show>(context: TraktContext()).map(JSONObject: item["show"].dictionaryObject) else {
                        watchedlist.append(media)
                        group.leave()
                        continue
                    }
                    episode.show = show
                    watchedlist.append(episode as! T)
                    group.leave()
                }
                group.notify(queue: .main, execute: { completion(watchedlist, nil) })
            }
        }
    }
    
    /**
     Retrieves users playback progress of video if applicable.
     
     - Parameter type: The type of the item (either movie or episode).
     
     - Parameter completion: The completion handler for the request containing a dictionary of either imdbIds or tvdbIds depending on the type selected as keys and the users corrisponding watched progress as values and an optional error. Eg. ["tt1431045": 0.5] means you have watched half of Deadpool.
     */
    open func getPlaybackProgress<T: Media>(forMediaOfType type: T.Type, completion:@escaping ([String: Float], NSError?) -> Void) {
        guard var credential = traktCredentials() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    DispatchQueue.global(qos: .background).async(execute: { completion([String: Float](), error) })
                }
            }
            let mediaType: String
            switch type {
            case is Movie.Type:
                mediaType = Trakt.movies
            case is Episode.Type:
                mediaType = Trakt.episodes
            default:
                fatalError("Only retrieving progress for movies and episode is supported.")
            }
            
            let queue = DispatchQueue(label: "com.popcorntimetv.popcornkit.response.queue", attributes: .concurrent)
            self.manager.request(Trakt.base + Trakt.sync + Trakt.playback + mediaType, parameters: Trakt.extended, headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON(queue: queue, options: .allowFragments) { response in
                guard let value = response.result.value else {
                    completion([:], response.result.error as NSError?)
                    return
                }
                let responseObject = JSON(value)
                var progressDict = [String: Float]()
                
                for (_, item) in responseObject {
                    guard let type = item["type"].string,
                        let progress = item["progress"].float,
                        progress != 0,
                        let media = Mapper<T>(context: TraktContext()).map(JSONObject: item[type].dictionaryObject)
                        else { continue }

                    progressDict[media.id] = progress/100.0
                }
                completion(progressDict, nil)
            }
        }
    }
    
    /**
     `Nil`s a users playback progress of a specified media. If `id` is invalid, 404 error will be thrown.
     
     - Parameter id: The imdbId of the movie or tvdbId of the episode.
     
     - Parameter completion: An optional completion handler called only if an error is thrown.
     */
    open func removePlaybackProgress(_ id: String, type: Trakt.MediaType, completion: ((NSError) -> Void)? = nil) {
        guard var credential = traktCredentials() else { return }
        DispatchQueue.global(qos: .background).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    DispatchQueue.global(qos: .background).async(execute: {completion?(error) })
                }
            }
            
            self.manager.request(Trakt.base + Trakt.sync + Trakt.playback + "/\(type.rawValue)", headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON { (response) in
                guard let value = response.result.value else {
                    if let error = response.result.error as NSError? {
                        completion?(error)
                    }
                    return
                }
                
                let responseObject = JSON(value)
                
                var playbackId: Int?
                
                for (_, item) in responseObject {
                    guard let t = item["type"].string,
                        let playback = item["id"].int
                        else { continue }
                    let ids = item[t]["ids"]
                    if (type == .movies && id == ids["imdb"].string) || (type == .episodes && Int(id) == ids["tvdb"].int) {
                        playbackId = playback
                        break
                    }
                }
                
                guard let id = playbackId else { return }
                
                self.manager.request(Trakt.base + Trakt.sync + Trakt.playback + "/\(id)", method: .delete, headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON { response in
                    if let error = response.result.error { completion?(error as NSError) }
                }
            }
        }
    }
    
    /**
     Removes a movie or episode from a users watched history.
     
     - Parameter id:    The imdbId or tvdbId of the movie, episode or show.
     - Parameter type:  The type of the item (movie or episode).
     
     - Parameter completion:    An optional completion handler called only if an error is thrown.
     */
    open func remove(_ id: String, fromWatchedlistOfType type: Trakt.MediaType, completion: ((NSError) -> Void)? = nil) {
        guard var credential = traktCredentials() else { return }
        DispatchQueue.global(qos: .background).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    DispatchQueue.global(qos: .background).async(execute: {completion?(error) })
                }
            }
            let parameters: [String: Any]
            if type == .movies {
                parameters = ["movies": [["ids": ["imdb": id]]]]
            } else if type == .episodes {
                parameters = ["episodes": [["ids": ["tvdb": Int(id)!]]]]
            } else {
                parameters = [:]
            }
            self.manager.request(Trakt.base + Trakt.sync + Trakt.history + Trakt.remove, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON { response in
                if let error = response.result.error { completion?(error as NSError) }
            }
        }
    }
    
    /**
     Adds specified media to users watch history.
     
     - Parameter id:    The imdbId or tvdbId of the media.
     - Parameter type:  The type of the item.
     
     - Parameter completion: The completion handler for the request containing an optional error if the request fails.
     */
    open func add(_ id: String, toWatchedlistOfType type: Trakt.MediaType, completion: ((NSError) -> Void)? = nil) {
        guard var credential = traktCredentials() else { return }
        DispatchQueue.global(qos: .background).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    DispatchQueue.global(qos: .background).async(execute: {completion?(error) })
                }
            }
            let parameters: [String: Any]
            if type == .movies {
                parameters = ["movies": [["ids": ["imdb": id]]]]
            } else if type == .episodes {
                parameters = ["episodes": [["ids": ["tvdb": Int(id)!]]]]
            } else {
                parameters = [:]
            }
            self.manager.request(Trakt.base + Trakt.sync + Trakt.history, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON { response in
                if let error = response.result.error { completion?(error as NSError) }
            }
        }
    }
    
    /**
     Retrieves cast and crew information for a movie or show.
     
     - Parameter type:  The type of the item (movie or show).
     - Parameter id:    The id of the movie or show.
     */
    open func getPeople(forMediaOfType type: Trakt.MediaType, id: String) async throws -> (actors: [Actor], crew: [Crew]) {
        let path = "/\(type.rawValue)/\(id)" + Trakt.people
        let traktPeople: TracktPeople = try await client.request(.get, path: path).responseMapable()
        return (actors: traktPeople.actors, crew: traktPeople.crew)
    }
    
    /**
     Retrieves users watchlist.
     
     - Parameter type: The type struct of the item eg. `Movie` or `Show`. Episodes not supported
     
     - Parameter completion: The completion handler for the request containing an array of media that the user has added to their watchlist and an optional error.
     */
    open func getWatchlist<T: Media>(forMediaOfType type: T.Type, completion:@escaping ([T], NSError?) -> Void) {
        guard var credential = traktCredentials() else { return }
        DispatchQueue.global(qos: .background).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    DispatchQueue.main.async(execute: { completion([T](), error) })
                }
            }
            let mediaType: String
            switch type {
            case is Movie.Type:
                mediaType = Trakt.movies
            case is Show.Type:
                mediaType = Trakt.shows
            default:
                mediaType = ""
            }
            let queue = DispatchQueue(label: "com.popcorntimetv.popcornkit.response.queue", attributes: .concurrent)
            self.manager.request(Trakt.base + Trakt.sync + Trakt.watchlist + mediaType, parameters: Trakt.extended, headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON(queue: queue, options: .allowFragments) { response in
                guard let value = response.result.value else { completion([T](), response.result.error as NSError?); return }
                let responseObject = JSON(value)
                var watchlist = [T]()
                let group = DispatchGroup()
                for (_, item) in responseObject {
                    guard let type = item["type"].string,
                        let media = Mapper<T>(context: TraktContext()).map(JSONObject: item[type].dictionaryObject)
                        else { continue }
                    group.enter()
                    let completion: (Media?, NSError?) -> Void = { (media, _) in
                        if let media = media { watchlist.append(media as! T) }
                        group.leave()
                    }
                    Task {
                        var item: Media? = nil
                        switch media {
                        case is Movie:
                            item = try? await MoviesApi.shared.getInfo(media.id)
                        case is Show:
                            item = try? await ShowsApi.shared.getInfo(media.id)
                        default:
                            break
                        }
                        completion(item, nil)
                    }
                }
                group.notify(queue: .main, execute: { completion(watchlist, nil) })
            }
        }
    }
    
    /**
     Adds specified media to users watchlist.
     
     - Parameter id:    The imdbId or tvdbId of the media.
     - Parameter type:  The type of the item.
     
     - Parameter completion: The completion handler for the request containing an optional error if the request fails.
     */
    open func add(_ id: String, toWatchlistOfType type: Trakt.MediaType, completion: ((NSError) -> Void)? = nil) {
        guard var credential = traktCredentials() else { return }
        DispatchQueue.global(qos: .background).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    DispatchQueue.main.async(execute: { completion?(error) })
                }
            }
            let parameters: [String: Any]
            if type == .episodes {
                parameters = ["episodes": [["ids": ["tvdb": Int(id)!]]]]
            } else {
                parameters = [type.rawValue: [["ids": ["imdb": id]]]]
            }
            self.manager.request(Trakt.base + Trakt.sync + Trakt.watchlist, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON { response in
                if let error = response.result.error { completion?(error as NSError) }
            }
        }
    }
    
    /**
     Removes specified media from users watchlist.
     
     - Parameter id:    The imdbId or tvdbId of the media.
     - Parameter type:  The type of the item.
     
     - Parameter completion: The completion handler for the request containing an optional error if the request fails.
     */
    open func remove(_ id: String, fromWatchlistOfType type: Trakt.MediaType, completion: ((NSError) -> Void)? = nil) {
        guard var credential = traktCredentials() else { return }
        DispatchQueue.global(qos: .background).async {
            if credential.expired {
                do {
                    credential = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token, refreshToken: credential.refreshToken!, clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                } catch let error as NSError {
                    DispatchQueue.main.async(execute: { completion?(error) })
                }
            }
            let parameters: [String: Any]
            if type == .episodes {
                parameters = ["episodes": [["ids": ["tvdb": Int(id)!]]]]
            } else {
                parameters = [type.rawValue: [["ids": ["imdb": id]]]]
            }
            self.manager.request(Trakt.base + Trakt.sync + Trakt.watchlist + Trakt.remove, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: Trakt.Headers.Authorization(credential.accessToken)).validate().responseJSON { response in
                if let error = response.result.error { completion?(error as NSError) }
            }
        }
    }
    
    /**
     Retrieves related media.
     
     - Parameter media: The media you would like to get more information about. **Please note:** only the imdbdId is used but an object needs to be passed in for Swift generics to work so creating a blank object with only an imdbId variable initialised will suffice if necessary.
     */
    open func getRelated<T: Media>(_ media: T) async throws -> [T] {
        let path = (media is Movie ? Trakt.movies : Trakt.shows) + "/\(media.id)" + Trakt.related
        let items: [T] = try await client.request(.get, path: path, parameters: Trakt.extended).responseMapable(context: TraktContext())
        
        return items.filter({ $0.tmdbId != nil })
    }
    
    
    /**
     Retrieves movies or shows that the person in cast/crew in.
     
     - Parameter id:    The id of the person you would like to get more information about.
     - Parameter type:  Just the type of the media is required for Swift generics to work.
     */
    open func getMediaCredits<T: Media>(forPersonWithId id: String, mediaType type: T.Type) async throws -> [T] {
        var typeString = (type is Movie.Type ? Trakt.movies : Trakt.shows)
        let path = Trakt.people + "/\(id)" + typeString

        typeString.removeLast() // Removes 's' from the type string
        typeString.removeFirst() // Removes '/' from the type string
        
        let mediaCredit: TracktMediaCredits<T> = try await client.request(.get, path: path, parameters: Trakt.extended)
            .responseMapable(context: TraktContext(type: typeString))
        
        return mediaCredit.medias.filter({ $0.tmdbId != nil })
    }
    
    /// Downloads users latest watchlist and watchedlist from Trakt.
    open func syncUserData() {
        let queue = DispatchQueue(label: "com.popcorntime.syncData", qos: .background, attributes: .concurrent, autoreleaseFrequency: .inherit, target: .global())
        queue.async{
            WatchedlistManager<Movie>.movie.getProgress()
            WatchedlistManager<Movie>.movie.getWatched()
            WatchlistManager<Movie>.movie.getWatchlist()
            WatchedlistManager<Episode>.episode.getProgress()
            WatchedlistManager<Episode>.episode.getWatched()
            WatchlistManager<Show>.show.getWatchlist()
        }
    }
    
//    /**
//     Requests tmdb id for object with imdb id.
//     
//     - Parameter id:            Imdb id of object.
//     - Parameter completion:    Completion handler containing optional tmdb id and an optional error.
//     */
//    open func getTMDBId(forImdbId id: String, completion: @escaping (Int?, NSError?) -> Void) {
//        self.manager.request(Trakt.base + Trakt.search + Trakt.imdb + "/\(id)", headers: Trakt.Headers.Default).validate().responseJSON { (response) in
//            guard let value = response.result.value else { completion(nil, response.result.error as NSError?); return }
//            let responseObject = JSON(value).arrayValue.first
//            
//            if let type = responseObject?["type"].string  {
//                completion(responseObject?[type]["ids"]["tmdb"].int, nil)
//            }
//            
//        }
//    }
    
    /**
     Requests tmdb id for object with imdb id.
     
     - Parameter id:            Imdb id of object.
     */
    open func getTMDBId(forImdbId id: String) async throws -> Int {
        let path = Trakt.search + Trakt.imdb + "/\(id)"
        let data = try await client.request(.get, path: path).responseData()
        let responseObject = JSON(data).arrayValue.first
        guard let type = responseObject?["type"].string, let id = responseObject?[type]["ids"]["tmdb"].int else {
            throw APIError.Type_.couldNoteDecodeResponse
        }
        return id
    }
    
//    /**
//     Requests episode info from tvdb.
//     
//     - Parameter id:            The tvdb identification code of the episode.
//     
//     - Parameter completion:    Completion handler for the request. Returns episode upon success, error upon failure.
//     */
//    open func getEpisodeInfo(forTvdb id: Int, completion: @escaping (Episode?, NSError?) -> Void) {
//        self.manager.request(Trakt.base + Trakt.search + Trakt.tvdb + "/\(id)", parameters:Trakt.extended, headers: Trakt.Headers.Default).validate().responseJSON { (response) in
//            guard let value = response.result.value else { completion(nil, response.result.error as NSError?); return }
//            let responseObject = JSON(value)[0]
//            
//            var episode = Mapper<Episode>(context: TraktContext()).map(JSONObject: responseObject["episode"].dictionaryObject)
//            episode?.show = Mapper<Show>(context: TraktContext()).map(JSONObject: responseObject["show"].dictionaryObject)
//            
//            TMDBManager.shared.getEpisodeScreenshots(forShowWithImdbId: episode?.show?.id, orTMDBId: episode?.show?.tmdbId, season: episode?.season ?? -1, episode: episode?.episode ?? -1) { (tmdb, image, error) in
//                if let tmdb = tmdb { episode?.show?.tmdbId = tmdb }
//                if let image = image { episode?.largeBackgroundImage = image }
//                
//                completion(episode, error)
//            }
//        }
//    }
    
    /**
     Searches Trakt for people (crew or actor).
     
     - Parameter person:        The name of the person to search.
     */
    open func search(forPerson person: String) async throws -> [Person] {
        // Type of person doesn't matter as it will succeed either way.
        let persons: [Crew] = try await client.request(.get, path: Trakt.search + Trakt.person, parameters: ["query": person]).responseMapable()
        return persons
    }
}

/// When mapping to movies or shows from Trakt, the JSON is formatted differently to the Popcorn API. This struct is used to distinguish from which API the Media is being mapped from.
struct TraktContext: MapContext {
    var type: String = ""
}

struct TracktPeople: Mappable {
    var actors: [Actor]
    var crew: [Crew]
    
    private init(_ map: Map) throws {
        actors = []
        crew = []
        let responseObject = JSON(map.JSON)
        
        for (_, actor) in responseObject["cast"] {
            guard let actor = Mapper<Actor>().map(JSONObject: actor.dictionaryObject) else { continue }
            actors.append(actor)
        }
        for (role, people) in responseObject["crew"] {
            guard let people = Mapper<Crew>().mapArray(JSONObject: people.arrayObject) else { continue }
            for var person in people {
                person.roleType = Role(rawValue: role) ?? .unknown
                crew.append(person)
            }
        }
    }
    
    init?(map: Map) {
        self.actors = []
        self.crew = []
    }
    
    public mutating func mapping(map: Map) {
        switch map.mappingType {
        case .fromJSON:
            if let people = try? TracktPeople(map) {
                self = people
            }
        case .toJSON:
            abort()
        }
    }
}

struct TracktMediaCredits<T: Media>: Mappable {
    var medias: [T]
    
    private init(_ map: Map) throws {
        let context = map.context as! TraktContext
        medias = []
        
        let responseObject = JSON(map.JSON)
        for item in [responseObject["crew"], responseObject["cast"]].compactMap({ $0.array }) {
            for json in item {
                if let payload = json[context.type].dictionaryObject,
                   let mediaItem = Mapper<T>(context: TraktContext()).map(JSONObject: payload) {
                    medias.append(mediaItem)
                }
            }
        }
    }
    
    init?(map: Map) {
        self.medias = []
    }
    
    public mutating func mapping(map: Map) {
        switch map.mappingType {
        case .fromJSON:
            if let mediaCredits = try? TracktMediaCredits<T>(map) {
                self = mediaCredits
            }
        case .toJSON:
            abort()
        }
    }
}

extension TraktManager {
    
    public func logout() {
        Session.traktCredentials = nil
    }
    
    public func isSignedIn() -> Bool {
        return Session.traktCredentials != nil
    }
    
    private func traktCredentials() -> OAuthCredential? {
        if let data = Session.traktCredentials,
           let credentials = try? JSONDecoder().decode(OAuthCredential.self, from: data) {
            return credentials
        }
        
        return nil
    }
    
    private func storeCredentials(_ credentials: OAuthCredential) {
        if let data = try? JSONEncoder().encode(credentials) {
            Session.traktCredentials = data
        }
    }
    
    /**
     Generate code to authenticate device on web.
     
     - Parameter completion: The completion handler for the request containing the code for the user to enter to the validation url (`https://trakt.tv/activate/authorize`), the code for the device to get the access token, the expiery date of the displat code and the time interval that the program is to check whether the user has authenticated and an optional error if request fails.
     */
    public func generateCode(completion: @escaping (String?, String?, Date?, TimeInterval?, NSError?) -> Void) {
        self.manager.request(Trakt.base + Trakt.auth + Trakt.device + Trakt.code, method: .post, parameters: ["client_id": Trakt.apiKey]).validate().responseJSON { (response) in
            guard let value = response.result.value as? [String: AnyObject], let displayCode = value["user_code"] as? String, let deviceCode = value["device_code"] as? String, let expire = value["expires_in"] as? Int, let interval = value["interval"]  as? Int else { completion(nil, nil, nil, nil, response.result.error as NSError?); return }
            completion(displayCode, deviceCode, Date().addingTimeInterval(Double(expire)), Double(interval), nil)
        }
    }
    
    public func check(deviceCode: String, success: @escaping () -> Void) {
        DispatchQueue.global(qos: .default).async {
            do {
                let credentials = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.device + Trakt.token, parameters: ["code": deviceCode], clientID: Trakt.apiKey, clientSecret: Trakt.apiSecret, useBasicAuthentication: false)
                self.storeCredentials(credentials)
                
                DispatchQueue.main.async {
                    success()
                }
            } catch { }
        }
    }
    
    /// 1 step of the authentication process, open this url in browser
    public func authorizationUrl(appScheme: String) -> URL {
        state = .random(of: 15)
        
        return URL(string: Trakt.base + Trakt.auth + "/authorize?client_id=" + Trakt.apiKey + "&redirect_uri=\(appScheme)%3A%2F%2Ftrakt&response_type=code&state=\(state!)")!
    }
    
    /**
     Second part of the authentication process
     
     - Parameter url: The redirect URI recieved from step 1.
     */
    public func authenticate(_ url: URL, completion: @escaping (_ error: Error?)->Void) {
        defer { state = nil }
        
        guard let query = url.query?.queryString,
            let code = query["code"],
            query["state"] == state
            else {
                let error = NSError(domain: "com.popcorntimetv.popcornkit.error", code: -1, userInfo: [NSLocalizedDescriptionKey: "An unknown error occured."])
                completion(error)
                return
        }
        
        DispatchQueue.global(qos: .default).async {
            do {
                let credentials = try OAuthCredential(Trakt.base + Trakt.auth + Trakt.token,
                                    code: code,
                                    redirectURI: "PopcornTime://trakt",
                                    clientID: Trakt.apiKey,
                                    clientSecret: Trakt.apiSecret,
                                    useBasicAuthentication: false)
                self.storeCredentials(credentials)
                DispatchQueue.main.sync {
                    completion(nil)
                }
            } catch let error as NSError {
                DispatchQueue.main.sync {
                    completion(error)
                }
            }
        }
    }
}
