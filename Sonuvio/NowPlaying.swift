import MediaPlayer
import UIKit

/// Pantalla de bloqueo y Centro de control cuando WebKit no ofrece navigator.mediaSession (iOS antiguos).
/// Recibe lo mismo que la notificación de Android: título, artista, portada, posición y duración.
final class NowPlaying {
    var send: ((String, Int?) -> Void)?
    private(set) var enabled = false
    private var playing = false
    private var artworkAddress: String?
    private var artwork: MPMediaItemArtwork?
    private var task: URLSessionDataTask?

    func enable() {
        guard !enabled else { return }
        enabled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.send?("play", nil); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.send?("pause", nil); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.send?(self.playing ? "pause" : "play", nil)
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.send?("next", nil); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.send?("previous", nil); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.send?("seek", Int(event.positionTime * 1000))
            return .success
        }
    }

    func update(json: String) {
        guard enabled,
              let data = json.data(using: .utf8),
              let media = try? JSONDecoder().decode(Media.self, from: data) else { return }
        playing = media.playing
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: media.title,
            MPMediaItemPropertyArtist: media.artist,
            MPMediaItemPropertyAlbumTitle: media.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(media.position) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: media.playing ? 1.0 : 0.0,
        ]
        if media.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(media.duration) / 1000 }
        if media.artwork == artworkAddress, let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else if media.artwork != artworkAddress {
            loadArtwork(media.artwork)
        }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = media.canSeek
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        guard enabled else { return }
        task?.cancel()
        artworkAddress = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func loadArtwork(_ address: String) {
        artworkAddress = address
        artwork = nil
        task?.cancel()
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else { return }
        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.artworkAddress == address else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artwork = artwork
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
        task?.resume()
    }

    private struct Media: Decodable {
        let title: String
        let artist: String
        let album: String
        let artwork: String
        let playing: Bool
        let position: Int
        let duration: Int
        let canSeek: Bool
    }
}
