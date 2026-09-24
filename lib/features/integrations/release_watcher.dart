import '../../core/library/album_grouping.dart';
import '../../core/library/library_repository.dart';
import '../../core/models/library_models.dart';
import '../../platform/bridges.dart';
import '../metadata/musicbrainz_client.dart';

class NewRelease {
  const NewRelease({required this.artist, required this.group});
  final Artist artist;
  final MbReleaseGroup group;

  String get message => '${artist.name} released "${group.title}"${group.primaryType == null ? '' : ' (${group.primaryType})'}';
}

/// Watches followed artists for new releases through MusicBrainz release-group browsing and
/// posts a notification (plan 7.3).
class ReleaseWatcher {
  ReleaseWatcher({required this.repo, required this.musicBrainz, required this.system, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final LibraryRepository repo;
  final MusicBrainzClient musicBrainz;
  final SystemBridge system;
  final DateTime Function() _now;

  /// Whether [g] came out after [lastCheck] and is not in the future. Only full dates or
  /// year-month values after the check month count (a bare year is too vague to alert on).
  static bool isNewSince(MbReleaseGroup g, DateTime lastCheck, DateTime now) {
    final d = g.firstReleaseDate;
    if (d == null) return false;
    final parts = d.split('-');
    if (parts.length < 2) return false;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null) return false;
    if (parts.length == 2) {
      // year-month: new only if the month is after the month of the last check
      final release = DateTime(y, m);
      return release.isAfter(DateTime(lastCheck.year, lastCheck.month)) && !release.isAfter(DateTime(now.year, now.month));
    }
    final day = int.tryParse(parts[2]);
    if (day == null) return false;
    final release = DateTime(y, m, day);
    return release.isAfter(lastCheck) && !release.isAfter(now);
  }

  /// Checks every followed artist that has a MusicBrainz id. The first check of an artist only
  /// records a baseline. Returns the alerts that were raised.
  Future<List<NewRelease>> checkAll({bool notify = true}) async {
    final artists = await repo.artists(followedOnly: true);
    final alerts = <NewRelease>[];
    final nowSeconds = _now().millisecondsSinceEpoch ~/ 1000;
    for (final a in artists) {
      final mbid = a.mbArtistId;
      if (mbid == null) continue;
      try {
        final groups = await musicBrainz.releaseGroups(mbid, types: 'album|ep|single', limit: 100);
        if (a.lastReleaseCheck != null) {
          final last = DateTime.fromMillisecondsSinceEpoch(a.lastReleaseCheck! * 1000);
          final ownedTitles = {for (final al in await repo.albums(artistId: a.id)) normalizeName(al.title)};
          for (final g in groups) {
            if (g.secondaryTypes.isNotEmpty) continue; // live / compilation / remix
            if (isNewSince(g, last, _now()) && !ownedTitles.contains(normalizeName(g.title))) {
              alerts.add(NewRelease(artist: a, group: g));
            }
          }
        }
        await repo.updateArtist(a.id, lastReleaseCheck: nowSeconds);
      } on Exception {
        continue; // offline: try again next time
      }
    }
    if (notify) {
      for (var i = 0; i < alerts.length && i < 5; i++) {
        try {
          await system.notify(id: 3000 + i, title: 'New release', body: alerts[i].message);
        } on PlatformFailure {
          break;
        }
      }
    }
    return alerts;
  }
}
