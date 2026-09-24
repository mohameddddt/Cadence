import '../../core/library/library_repository.dart';
import '../../core/library/smart_rules.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import 'lastfm_client.dart';
import 'library_matcher.dart';
import 'listenbrainz_client.dart';
import 'metadata_clients.dart';

class RadioPlan {
  const RadioPlan({required this.local, required this.suggestions, required this.basis});

  /// Tracks you already own, in playing order (seed first).
  final List<Track> local;

  /// Similar songs you do not have - offered as downloads.
  final List<WishTrack> suggestions;

  /// "Last.fm similar tracks", "ListenBrainz similar artists" or "your library".
  final String basis;
}

/// "Radio" mode: seed from the current track, follow similar tracks / artists, play what is
/// local and suggest downloads for the rest (plan 7.3).
class RadioService {
  RadioService({required this.repo, required this.settings, required this.lastFm, required this.listenBrainz});

  final LibraryRepository repo;
  final SettingsStore settings;
  final LastFmClient lastFm;
  final ListenBrainzClient listenBrainz;

  Future<RadioPlan> build(Track seed, {int count = 30}) async {
    final matcher = LibraryMatcher(repo);
    final local = <Track>[seed];
    final seen = {seed.id};
    final suggestions = <WishTrack>[];
    var basis = 'your library';

    // 1. Last.fm similar tracks
    if (lastFm.hasKey && seed.artistName != null) {
      try {
        final similar = await lastFm.similarTracks(seed.artistName!, seed.title, limit: 50);
        if (similar.isNotEmpty) basis = 'Last.fm similar tracks';
        for (final s in similar) {
          final t = await matcher.find(artist: s.artist, title: s.title, durationMs: s.durationSec == null ? null : s.durationSec! * 1000);
          if (t != null) {
            if (seen.add(t.id)) local.add(t);
          } else if (suggestions.length < 20) {
            suggestions.add(WishTrack(artist: s.artist, title: s.title, durationMs: s.durationSec == null ? null : s.durationSec! * 1000));
          }
        }
      } on Exception {
        // fall through to the next source
      }
    }

    // 2. ListenBrainz similar artists -> their tracks in the library
    if (local.length < count && seed.mbArtistId != null) {
      try {
        final artists = await listenBrainz.similarArtists(seed.mbArtistId!);
        if (artists.isNotEmpty && basis == 'your library') basis = 'ListenBrainz similar artists';
        for (final a in artists.take(20)) {
          final artist = await repo.artistByName(a.name);
          if (artist == null) continue;
          final tracks = await repo.tracks(artistId: artist.id, sort: TrackSort.playCount, descending: true, limit: 4);
          for (final t in tracks) {
            if (seen.add(t.id)) local.add(t);
          }
        }
      } on Exception {
        // fall through
      }
    }

    // 3. same artist, same genre - always available
    if (local.length < count) {
      final more = <Track>[
        if (seed.artistId != null) ...await repo.tracks(artistId: seed.artistId, sort: TrackSort.random, limit: 15),
        if (seed.genre != null) ...await repo.tracks(genre: seed.genre, sort: TrackSort.random, limit: 20),
      ];
      for (final t in more) {
        if (seen.add(t.id)) local.add(t);
      }
    }
    // keep the seed first, shuffle the rest of the similar tail lightly by recency of play
    final head = local.first;
    final tail = local.skip(1).take(count - 1).toList();
    return RadioPlan(local: [head, ...tail], suggestions: suggestions, basis: basis);
  }
}
