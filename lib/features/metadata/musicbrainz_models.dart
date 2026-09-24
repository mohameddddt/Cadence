/// Plain Dart views of the MusicBrainz JSON we care about.
library;

String artistCreditText(List<dynamic>? credit) {
  if (credit == null) return '';
  final b = StringBuffer();
  for (final c in credit) {
    final m = c as Map<String, dynamic>;
    b.write((m['name'] ?? (m['artist'] as Map?)?['name'] ?? '').toString());
    b.write((m['joinphrase'] ?? '').toString());
  }
  return b.toString().trim();
}

List<MbArtistRef> _artistRefs(List<dynamic>? credit) => [
      for (final c in credit ?? const [])
        if ((c as Map)['artist'] is Map)
          MbArtistRef(
            id: (c['artist'] as Map)['id'] as String,
            name: ((c['artist'] as Map)['name'] ?? '') as String,
          ),
    ];

class MbArtistRef {
  const MbArtistRef({required this.id, required this.name});
  final String id;
  final String name;
}

class MbRelease {
  const MbRelease({
    required this.id,
    required this.title,
    this.status,
    this.date,
    this.country,
    this.releaseGroupId,
    this.primaryType,
    this.secondaryTypes = const [],
    this.formats = const [],
    this.artistCredit = '',
    this.artists = const [],
    this.trackCount,
    this.trackNumber,
    this.discNumber,
    this.totalTracksOnDisc,
    this.releaseTrackId,
    this.label,
    this.barcode,
  });

  final String id;
  final String title;
  final String? status; // Official, Promotion, Bootleg, Pseudo-Release
  final String? date; // YYYY[-MM[-DD]]
  final String? country; // ISO 3166-1, or XW for worldwide
  final String? releaseGroupId;
  final String? primaryType; // Album, Single, EP, Broadcast, Other
  final List<String> secondaryTypes; // Compilation, Live, Remix, Soundtrack...
  final List<String> formats; // "Digital Media", "CD", "12\" Vinyl"...
  final String artistCredit;
  final List<MbArtistRef> artists;
  final int? trackCount;
  final int? trackNumber; // position of the recording on this release
  final int? discNumber;
  final int? totalTracksOnDisc;
  final String? releaseTrackId;
  final String? label;
  final String? barcode;

  int? get year {
    final d = date;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }

  /// Parses a release object as returned inside `recording?inc=releases...`,
  /// `release/{id}` or search results.
  factory MbRelease.fromJson(Map<String, dynamic> j, {int? trackNo, int? discNo, int? discTrackCount, String? releaseTrackId}) {
    final rg = j['release-group'] as Map<String, dynamic>?;
    final media = (j['media'] as List?) ?? const [];
    final formats = <String>[
      for (final m in media)
        if ((m as Map)['format'] != null) m['format'] as String,
    ];
    var count = j['track-count'] as int?;
    count ??= media.isEmpty
        ? null
        : media.fold<int>(0, (a, m) => a + (((m as Map)['track-count'] as int?) ?? 0));
    String? label;
    final li = j['label-info'] as List?;
    if (li != null && li.isNotEmpty) label = ((li.first as Map)['label'] as Map?)?['name'] as String?;
    return MbRelease(
      id: j['id'] as String,
      title: (j['title'] ?? '') as String,
      status: j['status'] as String?,
      date: (j['date'] as String?)?.isEmpty == true ? null : j['date'] as String?,
      country: j['country'] as String?,
      releaseGroupId: rg?['id'] as String?,
      primaryType: rg?['primary-type'] as String?,
      secondaryTypes: [for (final t in (rg?['secondary-types'] as List?) ?? const []) t as String],
      formats: formats,
      artistCredit: artistCreditText(j['artist-credit'] as List?),
      artists: _artistRefs(j['artist-credit'] as List?),
      trackCount: count,
      trackNumber: trackNo,
      discNumber: discNo,
      totalTracksOnDisc: discTrackCount,
      releaseTrackId: releaseTrackId,
      label: label,
      barcode: (j['barcode'] as String?)?.isEmpty == true ? null : j['barcode'] as String?,
    );
  }
}

class MbRecording {
  const MbRecording({
    required this.id,
    required this.title,
    this.artistCredit = '',
    this.artists = const [],
    this.lengthMs,
    this.isrcs = const [],
    this.releases = const [],
    this.genres = const [],
    this.score,
  });

  final String id;
  final String title;
  final String artistCredit;
  final List<MbArtistRef> artists;
  final int? lengthMs;
  final List<String> isrcs;
  final List<MbRelease> releases;
  final List<String> genres;

  /// MusicBrainz search score (0-100) when this came from a search.
  final int? score;

  factory MbRecording.fromJson(Map<String, dynamic> j) {
    final releases = <MbRelease>[];
    for (final r in (j['releases'] as List?) ?? const []) {
      final rm = (r as Map).cast<String, dynamic>();
      int? tn, dn, dtc;
      String? rtid;
      final media = rm['media'] as List?;
      if (media != null) {
        for (final m in media) {
          final mm = (m as Map).cast<String, dynamic>();
          final tracks = (mm['tracks'] ?? mm['track']) as List?;
          if (tracks != null && tracks.isNotEmpty) {
            final t = (tracks.first as Map).cast<String, dynamic>();
            tn = int.tryParse('${t['number'] ?? t['position']}') ?? (t['position'] as int?);
            dn = mm['position'] as int?;
            dtc = mm['track-count'] as int?;
            rtid = t['id'] as String?;
            break;
          }
        }
      }
      releases.add(MbRelease.fromJson(rm, trackNo: tn, discNo: dn, discTrackCount: dtc, releaseTrackId: rtid));
    }
    final genres = <String>[
      for (final g in (j['genres'] as List?) ?? const [])
        if ((g as Map)['name'] != null) g['name'] as String,
    ];
    return MbRecording(
      id: j['id'] as String,
      title: (j['title'] ?? '') as String,
      artistCredit: artistCreditText(j['artist-credit'] as List?),
      artists: _artistRefs(j['artist-credit'] as List?),
      lengthMs: j['length'] as int?,
      isrcs: [for (final i in (j['isrcs'] as List?) ?? const []) i as String],
      releases: releases,
      genres: genres,
      score: j['score'] is int ? j['score'] as int : int.tryParse('${j['score']}'),
    );
  }

  MbRecording copyWith({List<MbRelease>? releases, int? score}) => MbRecording(
        id: id,
        title: title,
        artistCredit: artistCredit,
        artists: artists,
        lengthMs: lengthMs,
        isrcs: isrcs,
        releases: releases ?? this.releases,
        genres: genres,
        score: score ?? this.score,
      );
}

/// Extra release-level detail: the full tracklist (for "download missing tracks").
class MbTrack {
  const MbTrack({
    required this.number,
    required this.disc,
    required this.title,
    required this.recordingId,
    this.lengthMs,
    this.artistCredit = '',
    this.releaseTrackId,
  });

  final int number;
  final int disc;
  final String title;
  final String recordingId;
  final int? lengthMs;
  final String artistCredit;
  final String? releaseTrackId;
}

class MbReleaseDetail {
  const MbReleaseDetail({required this.release, required this.tracks});

  final MbRelease release;
  final List<MbTrack> tracks;

  factory MbReleaseDetail.fromJson(Map<String, dynamic> j) {
    final tracks = <MbTrack>[];
    final media = (j['media'] as List?) ?? const [];
    for (final m in media) {
      final mm = (m as Map).cast<String, dynamic>();
      final disc = (mm['position'] as int?) ?? 1;
      for (final t in (mm['tracks'] as List?) ?? const []) {
        final tm = (t as Map).cast<String, dynamic>();
        final rec = (tm['recording'] as Map?)?.cast<String, dynamic>();
        if (rec == null) continue;
        tracks.add(MbTrack(
          number: (tm['position'] as int?) ?? int.tryParse('${tm['number']}') ?? tracks.length + 1,
          disc: disc,
          title: (tm['title'] ?? rec['title'] ?? '') as String,
          recordingId: rec['id'] as String,
          lengthMs: (tm['length'] ?? rec['length']) as int?,
          artistCredit: artistCreditText((tm['artist-credit'] ?? rec['artist-credit']) as List?),
          releaseTrackId: tm['id'] as String?,
        ));
      }
    }
    return MbReleaseDetail(release: MbRelease.fromJson(j), tracks: tracks);
  }
}
