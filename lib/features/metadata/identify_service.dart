import 'dart:async';

import '../../core/library/library_repository.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import '../../core/util/string_similarity.dart';
import '../../platform/bridges.dart';
import 'acoustid_client.dart';
import 'fingerprint_service.dart';
import 'musicbrainz_client.dart';
import 'musicbrainz_models.dart';
import 'release_picker.dart';
import 'tag_writer.dart';
import 'title_cleaner.dart';

/// The tags an identification would write.
class ProposedTags {
  const ProposedTags({
    required this.title,
    required this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.isrc,
    this.date,
    this.trackNo,
    this.trackTotal,
    this.discNo,
    this.discTotal,
    this.mbRecordingId,
    this.mbReleaseTrackId,
    this.mbReleaseId,
    this.mbReleaseGroupId,
    this.mbArtistId,
    this.acoustId,
    this.label,
  });

  final String title;
  final String artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final String? isrc;
  final String? date;
  final int? trackNo;
  final int? trackTotal;
  final int? discNo;
  final int? discTotal;
  final String? mbRecordingId;
  final String? mbReleaseTrackId;
  final String? mbReleaseId;
  final String? mbReleaseGroupId;
  final String? mbArtistId;
  final String? acoustId;
  final String? label;

  int? get year => (date == null || date!.length < 4) ? null : int.tryParse(date!.substring(0, 4));

  /// Values for the native tag writer (keys match TagIO.java).
  TagUpdate toUpdate({bool keepExistingGenre = false, String? existingGenre}) {
    final u = TagUpdate();
    void put(String k, Object? v) {
      if (v != null && (v is! String || v.isNotEmpty)) u.set(k, v is int ? v.toString() : v);
    }

    put('title', title);
    put('artist', artist);
    put('album', album);
    put('albumArtist', albumArtist);
    put('date', date);
    put('trackNo', trackNo);
    put('trackTotal', trackTotal);
    put('discNo', discNo);
    put('discTotal', discTotal);
    put('isrc', isrc);
    if (!(keepExistingGenre && (existingGenre?.isNotEmpty ?? false))) put('genre', genre);
    put('mbRecordingId', mbRecordingId);
    put('mbReleaseTrackId', mbReleaseTrackId);
    put('mbReleaseId', mbReleaseId);
    put('mbReleaseGroupId', mbReleaseGroupId);
    put('mbArtistId', mbArtistId);
    put('acoustId', acoustId);
    return u;
  }

  /// Human-readable rows for the "current vs proposed" review screen.
  Map<String, String?> toDisplayMap() => {
        'Title': title,
        'Artist': artist,
        'Album': album,
        'Album artist': albumArtist,
        'Track': trackNo == null ? null : (trackTotal == null ? '$trackNo' : '$trackNo/$trackTotal'),
        'Disc': discNo == null ? null : (discTotal == null ? '$discNo' : '$discNo/$discTotal'),
        'Year': date,
        'Genre': genre,
        'ISRC': isrc,
        'Label': label,
      };
}

class IdentifyCandidate {
  const IdentifyCandidate({
    required this.recording,
    required this.confidence,
    required this.origin,
    required this.proposed,
    this.release,
    this.acoustId,
  });

  final MbRecording recording;
  final MbRelease? release;
  final double confidence; // 0..1
  final String origin; // tags | acoustid | text
  final String? acoustId;
  final ProposedTags proposed;

  String get summary => '${recording.artistCredit} - ${recording.title}${release == null ? '' : ' (${release!.title})'}';
}

class IdentifyResult {
  const IdentifyResult({required this.candidates, required this.threshold, this.notes = const []});

  final List<IdentifyCandidate> candidates;
  final double threshold;

  /// Why nothing (or something odd) happened: no API key, offline, too short...
  final List<String> notes;

  IdentifyCandidate? get best => candidates.isEmpty ? null : candidates.first;
  bool get autoAccept => best != null && best!.confidence >= threshold;
}

/// Identification strategy from the plan, in order:
///  1. MBIDs already in the tags -> trust them,
///  2. acoustic fingerprint -> AcoustID -> MusicBrainz,
///  3. cleaned-title text search on MusicBrainz,
///  4. manual (UI calls [searchManual]).
class IdentifyService {
  IdentifyService({
    required this.repo,
    required this.settings,
    required this.musicBrainz,
    required this.acoustId,
    required this.fingerprints,
    required this.tagWriter,
    required this.bridges,
  });

  final LibraryRepository repo;
  final SettingsStore settings;
  final MusicBrainzClient musicBrainz;
  final AcoustIdClient acoustId;
  final FingerprintService fingerprints;
  final TagWriter tagWriter;
  final Bridges bridges;

  bool _providerOn(String id) => settings.metadataProviders.contains(id);

  ReleasePicker get _picker => ReleasePicker(preferredCountry: settings.preferredCountry);

  Future<IdentifyResult> identify(Track track, {bool useFingerprint = true, void Function(String stage)? onStage}) async {
    final threshold = settings.autoAcceptThreshold;
    final notes = <String>[];
    final byId = <String, IdentifyCandidate>{};

    void add(IdentifyCandidate c) {
      final old = byId[c.recording.id];
      if (old == null || c.confidence > old.confidence) byId[c.recording.id] = c;
    }

    // 1. tags ------------------------------------------------------------------
    if (_providerOn('tags') && track.mbRecordingId != null && track.mbRecordingId!.isNotEmpty) {
      onStage?.call('Reading MusicBrainz id from tags');
      try {
        final rec = await musicBrainz.recording(track.mbRecordingId!);
        if (rec != null) add(_candidate(track, rec, 1.0, 'tags', acoustId: track.acoustId));
      } on Exception catch (e) {
        notes.add('MusicBrainz lookup failed: $e');
      }
      if (byId.isNotEmpty) return IdentifyResult(candidates: byId.values.toList(), threshold: threshold, notes: notes);
    }

    // 2. fingerprint -----------------------------------------------------------
    if (useFingerprint && _providerOn('acoustid')) {
      if (!acoustId.isConfigured) {
        notes.add('AcoustID key missing - add it in Settings > Accounts for fingerprint matching.');
      } else {
        onStage?.call('Fingerprinting');
        try {
          final fp = await fingerprints.forTrack(track);
          if (fp == null) {
            notes.add('File too short or unreadable for fingerprinting.');
          } else {
            onStage?.call('Asking AcoustID');
            final results = await acoustId.lookup(fingerprint: fp.encoded, durationSeconds: fp.durationSeconds);
            var looked = 0;
            for (final r in results) {
              if (r.score < 0.5) continue;
              for (final ar in r.recordings) {
                if (looked >= 4) break;
                looked++;
                onStage?.call('Fetching MusicBrainz data');
                final rec = await musicBrainz.recording(ar.id);
                if (rec == null) continue;
                var conf = r.score;
                if (track.durationMs > 0 && rec.lengthMs != null && (track.durationMs - rec.lengthMs!).abs() > 15000) conf *= 0.8;
                add(_candidate(track, rec, conf, 'acoustid', acoustId: r.acoustId));
              }
            }
            if (byId.isEmpty) notes.add('AcoustID knows no match for this recording.');
          }
        } on PlatformFailure catch (e) {
          notes.add('Could not decode audio for fingerprinting: ${e.message}');
        } on Exception catch (e) {
          notes.add('AcoustID failed: $e');
        }
      }
    }

    // 3. text search -------------------------------------------------------------
    final good = byId.values.any((c) => c.confidence >= threshold);
    if (!good && _providerOn('musicbrainz')) {
      onStage?.call('Searching MusicBrainz');
      try {
        final cleaner = TitleCleaner.fromSettings(settings.titleRules);
        final cleaned = cleaner.clean(track.title, uploader: track.artistName);
        final artist = track.artistName ?? cleaned.artist;
        final title = cleaned.title;
        var hits = await musicBrainz.searchRecordings(title: title, artist: artist, durationMs: track.durationMs);
        if (hits.isEmpty && artist != null) {
          // Duration windows are strict; retry without it before giving up.
          hits = await musicBrainz.searchRecordings(title: title, artist: artist);
        }
        for (final rec in hits) {
          add(_candidate(track, rec, _textConfidence(track, title, artist, rec), 'text'));
        }
      } on Exception catch (e) {
        notes.add('MusicBrainz search failed: $e');
      }
    }

    final list = byId.values.toList()..sort((a, b) => b.confidence.compareTo(a.confidence));
    return IdentifyResult(candidates: list, threshold: threshold, notes: notes);
  }

  /// Manual search from the review screen.
  Future<List<IdentifyCandidate>> searchManual(Track track, {required String title, String? artist, String? album}) async {
    final hits = await musicBrainz.searchRecordings(title: title, artist: artist, album: album, limit: 15);
    final out = [for (final r in hits) _candidate(track, r, _textConfidence(track, title, artist, r), 'text')];
    out.sort((a, b) => b.confidence.compareTo(a.confidence));
    return out;
  }

  /// Confidence for a text-search hit: MusicBrainz' own score weighed by how well the title,
  /// artist and duration agree - a 100 score for a different song must not auto-accept.
  double _textConfidence(Track t, String title, String? artist, MbRecording rec) {
    final score = (rec.score ?? 70) / 100.0;
    final titleSim = StringSimilarity.ratio(title, rec.title);
    final artistSim = artist == null || artist.isEmpty ? 0.7 : StringSimilarity.ratio(artist, rec.artistCredit);
    var dur = 1.0;
    if (t.durationMs > 0 && rec.lengthMs != null) {
      final diff = (t.durationMs - rec.lengthMs!).abs();
      dur = diff <= 2000 ? 1.0 : diff <= 5000 ? 0.95 : diff <= 10000 ? 0.85 : 0.6;
    }
    return (score * (0.5 + 0.5 * titleSim) * (0.6 + 0.4 * artistSim) * dur).clamp(0.0, 1.0);
  }

  IdentifyCandidate _candidate(Track t, MbRecording rec, double confidence, String origin, {String? acoustId}) {
    // Prefer a release matching an album the file already claims, then the general ranking.
    var pool = rec.releases;
    if (t.albumTitle != null && t.albumTitle!.isNotEmpty) {
      final same = pool.where((r) => StringSimilarity.ratio(r.title, t.albumTitle) >= 0.9).toList();
      if (same.isNotEmpty) pool = same;
    }
    final release = _picker.pick(pool);
    final artist = rec.artists.isEmpty ? null : rec.artists.first;
    final proposed = ProposedTags(
      title: rec.title,
      artist: rec.artistCredit.isEmpty ? (t.artistName ?? '') : rec.artistCredit,
      album: release?.title,
      albumArtist: release?.artistCredit.isEmpty == false ? release!.artistCredit : null,
      genre: rec.genres.isEmpty ? null : _titleCase(rec.genres.first),
      isrc: rec.isrcs.isEmpty ? null : rec.isrcs.first,
      date: release?.date,
      trackNo: release?.trackNumber,
      trackTotal: release?.totalTracksOnDisc,
      discNo: release?.discNumber,
      mbRecordingId: rec.id,
      mbReleaseTrackId: release?.releaseTrackId,
      mbReleaseId: release?.id,
      mbReleaseGroupId: release?.releaseGroupId,
      mbArtistId: artist?.id,
      acoustId: acoustId,
      label: release?.label,
    );
    return IdentifyCandidate(recording: rec, release: release, confidence: confidence, origin: origin, proposed: proposed, acoustId: acoustId);
  }

  static String _titleCase(String s) => s.split(' ').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  // ------------------------------------------------------------------- apply

  /// Applies [candidate]: writes tags (when enabled), updates the database, marks the track
  /// as identified. Returns how the file write went.
  Future<TagWriteOutcome> apply(Track track, IdentifyCandidate candidate) async {
    final p = candidate.proposed;
    var outcome = TagWriteOutcome.written;
    if (settings.writeTagsToFiles) {
      final update = p.toUpdate(keepExistingGenre: true, existingGenre: track.genre);
      outcome = await tagWriter.write(track, update);
    }
    // The tag write changed the file: pick up its new size/mtime (TagWriter stored them).
    final fresh = await repo.trackById(track.id) ?? track;
    final draft = TrackDraft(
      filePath: track.filePath,
      title: p.title,
      artist: p.artist,
      albumArtist: p.albumArtist ?? track.albumArtist,
      album: p.album ?? track.albumTitle,
      trackNo: p.trackNo ?? track.trackNo,
      discNo: p.discNo ?? track.discNo,
      durationMs: track.durationMs,
      year: p.year ?? track.year,
      genre: (track.genre != null && track.genre!.isNotEmpty) ? track.genre : p.genre,
      bitrate: track.bitrate,
      format: track.format,
      sizeBytes: fresh.sizeBytes,
      fileMtime: fresh.fileMtime,
      contentUri: track.contentUri,
      folder: track.folder,
      sourceUrl: track.sourceUrl,
      audioHash: track.audioHash,
      mbRecordingId: p.mbRecordingId,
      mbReleaseId: p.mbReleaseId,
      mbReleaseGroupId: p.mbReleaseGroupId,
      mbArtistId: p.mbArtistId,
      acoustId: p.acoustId ?? track.acoustId,
      isrc: p.isrc ?? track.isrc,
      replayGainTrack: track.replayGainTrack,
      replayGainAlbum: track.replayGainAlbum,
      hasEmbeddedArt: track.hasEmbeddedArt,
      identifyState: IdentifyState.matched,
    )..source = track.source;
    await repo.upsertTrack(draft);
    await repo.updateTrackColumns(track.id, {'identify_score': candidate.confidence});
    return outcome;
  }

  Future<void> markNeedsReview(Track track) => repo.updateTrackColumns(track.id, {'identify_state': IdentifyState.needsReview});

  Future<void> skip(Track track) => repo.updateTrackColumns(track.id, {'identify_state': IdentifyState.skipped});

  /// Batch "Identify all unmatched tracks". Confident matches are applied; the rest go to
  /// the review queue. Runs sequentially - the network calls are rate limited anyway.
  Stream<BatchIdentifyProgress> identifyAll({List<Track>? tracks, bool useFingerprint = true, bool Function()? isCancelled}) async* {
    final list = tracks ?? await repo.unidentified();
    var done = 0, matched = 0, review = 0, failed = 0;
    for (final t in list) {
      if (isCancelled?.call() ?? false) break;
      yield BatchIdentifyProgress(done, list.length, matched, review, failed, current: t);
      try {
        final r = await identify(t, useFingerprint: useFingerprint);
        if (r.autoAccept) {
          await apply(t, r.best!);
          matched++;
        } else if (r.candidates.isNotEmpty) {
          await markNeedsReview(t);
          review++;
        }
      } on Exception {
        failed++;
      }
      done++;
    }
    yield BatchIdentifyProgress(done, list.length, matched, review, failed);
  }
}

class BatchIdentifyProgress {
  const BatchIdentifyProgress(this.done, this.total, this.matched, this.needsReview, this.failed, {this.current});
  final int done;
  final int total;
  final int matched;
  final int needsReview;
  final int failed;
  final Track? current;
  bool get finished => done >= total;
}
