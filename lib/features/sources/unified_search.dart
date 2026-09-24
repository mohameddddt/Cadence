import 'dart:async';

import '../../core/library/library_repository.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import 'direct_sources.dart';
import 'source_provider.dart';

enum SectionStatus { loading, done, failed, disabled }

/// One results group in the search screen: "Local", "YouTube", "Internet Archive"...
class SearchSection {
  const SearchSection({
    required this.id,
    required this.label,
    required this.status,
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.remote = const [],
    this.error,
  });

  final String id;
  final String label;
  final SectionStatus status;
  final List<Track> tracks;
  final List<Album> albums;
  final List<Artist> artists;
  final List<RemoteTrack> remote;
  final String? error;

  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty && remote.isEmpty;

  SearchSection copyWith({SectionStatus? status, List<RemoteTrack>? remote, String? error}) => SearchSection(
        id: id,
        label: label,
        status: status ?? this.status,
        tracks: tracks,
        albums: albums,
        artists: artists,
        remote: remote ?? this.remote,
        error: error ?? this.error,
      );
}

/// One box, results grouped Local | YouTube | SoundCloud | Internet Archive | ... (plan phase 8).
///
/// Local results come back immediately; each remote provider fills in on its own so one slow
/// or broken source never blocks the rest.
class UnifiedSearch {
  UnifiedSearch({
    required this.repo,
    required this.settings,
    required this.registry,
    this.remoteTimeout = const Duration(seconds: 25),
  });

  final LibraryRepository repo;
  final SettingsStore settings;
  final SourceRegistry registry;
  final Duration remoteTimeout;

  /// Emits the full list of sections every time one of them changes.
  Stream<List<SearchSection>> search(String query, {bool includeRemote = true, Set<String>? onlyProviders}) {
    final controller = StreamController<List<SearchSection>>();
    final q = query.trim();
    if (q.isEmpty) {
      controller.add(const []);
      controller.close();
      return controller.stream;
    }
    () async {
      final sections = <SearchSection>[];
      void emit() {
        if (!controller.isClosed) controller.add(List.of(sections));
      }

      final tracks = await repo.searchTracks(q, limit: 50);
      final albums = await repo.albums(query: q);
      final artists = await repo.artists(query: q);
      sections.add(SearchSection(id: 'local', label: 'On this device', status: SectionStatus.done, tracks: tracks, albums: albums.take(12).toList(), artists: artists.take(12).toList()));
      emit();

      if (includeRemote) {
        final providers = registry.enabled.where((p) => p.supportsSearch && (onlyProviders == null || onlyProviders.contains(p.id))).toList();
        for (final p in providers) {
          sections.add(SearchSection(id: p.id, label: p.label, status: SectionStatus.loading));
        }
        emit();
        await Future.wait([
          for (final p in providers)
            () async {
              final i = sections.indexWhere((s) => s.id == p.id);
              try {
                final results = await p.search(q).timeout(remoteTimeout);
                sections[i] = sections[i].copyWith(status: SectionStatus.done, remote: results);
              } on TimeoutException {
                sections[i] = sections[i].copyWith(status: SectionStatus.failed, error: 'Timed out');
              } on Object catch (e) {
                sections[i] = sections[i].copyWith(status: SectionStatus.failed, error: _friendly(e));
              }
              emit();
            }(),
        ]);
      }
      await controller.close();
    }();
    return controller.stream;
  }

  static String _friendly(Object e) {
    final s = e.toString();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}
