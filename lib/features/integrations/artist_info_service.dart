import 'dart:io';
import 'dart:typed_data';

import '../../core/library/album_grouping.dart';
import '../../core/library/library_repository.dart';
import '../../core/models/library_models.dart';
import '../../core/net/http_service.dart';
import '../../core/util/string_similarity.dart';
import '../cover/image_processing.dart';
import '../metadata/musicbrainz_client.dart';
import 'lastfm_client.dart';
import 'metadata_clients.dart';

class ArtistLinks {
  const ArtistLinks(this.links);
  final Map<String, String> links;

  String? get wikipedia => links['wikipedia'];
  String? get official => links['official homepage'];
  bool get isEmpty => links.isEmpty;
}

/// Bio + photo + links for artist pages (plan 5.3 and 7.2), gathered from several free sources
/// and cached in the artists table so pages open instantly offline.
class ArtistInfoService {
  ArtistInfoService({
    required this.repo,
    required this.http,
    required this.musicBrainz,
    required this.fanart,
    required this.audioDb,
    required this.wiki,
    required this.deezer,
    required this.lastFm,
    required this.imagesDir,
    Future<Uint8List> Function(Uint8List)? processor,
    this.refreshAfter = const Duration(days: 30),
  }) : _process = processor ?? ((b) => ImageProcessing.processCoverAsync(b, maxSize: 800));

  final LibraryRepository repo;
  final HttpService http;
  final MusicBrainzClient musicBrainz;
  final FanartClient fanart;
  final AudioDbClient audioDb;
  final WikiClient wiki;
  final DeezerClient deezer;
  final LastFmClient lastFm;
  final Directory Function() imagesDir;
  final Future<Uint8List> Function(Uint8List) _process;
  final Duration refreshAfter;

  final Map<int, Future<Artist>> _inFlight = {};

  /// Fills in whatever is missing for [artist] (MBID, bio, photo). Safe to call on every visit.
  Future<Artist> refresh(Artist artist, {bool force = false}) {
    return _inFlight[artist.id] ??= _refresh(artist, force).whenComplete(() {
      _inFlight.remove(artist.id);
    });
  }

  Future<Artist> _refresh(Artist artist, bool force) async {
    final fresh = artist.infoFetchedAt != null &&
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(artist.infoFetchedAt! * 1000)) < refreshAfter;
    if (!force && fresh && artist.bio != null && (artist.imagePath != null && File(artist.imagePath!).existsSync())) return artist;

    // 1. MusicBrainz id
    var mbid = artist.mbArtistId;
    MbArtist? mb;
    try {
      if (mbid == null) {
        final hits = await musicBrainz.searchArtists(artist.name, limit: 3);
        for (final h in hits) {
          if (StringSimilarity.ratio(h.name, artist.name) >= 0.95) {
            mbid = h.id;
            break;
          }
        }
      }
      if (mbid != null) mb = await musicBrainz.artist(mbid);
    } on Object {
      // offline: keep what we have
    }

    // 2. bio: AudioDB -> Wikipedia -> Last.fm
    String? bio = artist.bio;
    String? bioSource = artist.bioSource;
    String? imageUrl = artist.imageUrl;
    if (bio == null || force) {
      final r = await _bio(artist.name, mbid, mb);
      if (r != null) {
        bio = r.$1;
        bioSource = r.$2;
        imageUrl ??= r.$3;
      }
    }

    // 3. photo: fanart -> AudioDB -> Wikimedia -> Deezer -> Last.fm
    String? imagePath = artist.imagePath;
    if (imagePath == null || !File(imagePath).existsSync() || force) {
      final url = await _image(artist.name, mbid, mb) ?? imageUrl;
      if (url != null) {
        try {
          final bytes = Uint8List.fromList(await http.getBytes(url));
          final jpg = await _process(bytes);
          final f = File('${imagesDir().path}/artist_${artist.id}.jpg')..parent.createSync(recursive: true);
          await f.writeAsBytes(jpg, flush: true);
          imagePath = f.path;
          imageUrl = url;
        } on Object {
          // keep the URL for a later retry
          imageUrl = url;
        }
      }
    }

    await repo.updateArtist(artist.id, mbArtistId: mbid, bio: bio, bioSource: bioSource, imagePath: imagePath, imageUrl: imageUrl, touchInfo: true);
    return await repo.artistById(artist.id) ?? artist;
  }

  Future<(String, String, String?)?> _bio(String name, String? mbid, MbArtist? mb) async {
    try {
      if (mbid != null) {
        final a = await audioDb.artistByMbid(mbid);
        if (a?.bio != null && a!.bio!.length > 40) return (a.bio!, 'TheAudioDB', a.thumb);
      }
    } on Object {
      // next source
    }
    try {
      final q = WikiClient.wikidataId(mb?.link('wikidata'));
      if (q != null) {
        final e = await wiki.entity(q);
        if (e.title != null) {
          final s = await wiki.summary(e.title!);
          if (s != null) return (s.extract, 'Wikipedia', s.thumbnail);
        }
      }
    } on Object {
      // next source
    }
    try {
      final info = await lastFm.artistInfo(name, mbid: mbid);
      if (info?.bio != null && info!.bio!.length > 40) return (info.bio!, 'Last.fm', info.imageUrl);
    } on Object {
      // no bio available
    }
    return null;
  }

  Future<String?> _image(String name, String? mbid, MbArtist? mb) async {
    try {
      if (mbid != null) {
        final f = await fanart.artistThumb(mbid);
        if (f != null) return f;
        final a = await audioDb.artistByMbid(mbid);
        if (a?.thumb != null) return a!.thumb;
      }
    } on Object {
      // next
    }
    try {
      final q = WikiClient.wikidataId(mb?.link('wikidata'));
      if (q != null) {
        final e = await wiki.entity(q);
        if (e.imageFile != null) return WikiClient.commonsUrl(e.imageFile!);
      }
    } on Object {
      // next
    }
    try {
      final d = await deezer.findArtist(name);
      if (d?.pictureXl != null) return d!.pictureXl;
    } on Object {
      // next
    }
    return null;
  }

  /// Web links from MusicBrainz relations (Wikipedia, Discogs, Bandcamp, homepage...).
  Future<ArtistLinks> links(Artist artist) async {
    if (artist.mbArtistId == null) return const ArtistLinks({});
    try {
      final mb = await musicBrainz.artist(artist.mbArtistId!);
      if (mb == null) return const ArtistLinks({});
      const wanted = ['official homepage', 'wikipedia', 'discogs', 'bandcamp', 'allmusic', 'social network', 'youtube', 'soundcloud', 'lastfm', 'streaming music'];
      return ArtistLinks({
        for (final t in wanted)
          if (mb.link(t) != null) t: mb.link(t)!,
      });
    } on Object {
      return const ArtistLinks({});
    }
  }

  /// Studio albums by [artist] on MusicBrainz that are not in the local library
  /// ("download missing albums").
  Future<({List<MbReleaseGroup> owned, List<MbReleaseGroup> missing})> discography(Artist artist) async {
    if (artist.mbArtistId == null) return (owned: <MbReleaseGroup>[], missing: <MbReleaseGroup>[]);
    final groups = await musicBrainz.releaseGroups(artist.mbArtistId!, types: 'album|ep');
    final studio = groups.where((g) => g.secondaryTypes.isEmpty).toList();
    final local = await repo.albums(artistId: artist.id);
    final localKeys = {for (final a in local) normalizeName(a.title)};
    final localGroupIds = {for (final a in local) if (a.mbReleaseGroupId != null) a.mbReleaseGroupId!};
    final owned = <MbReleaseGroup>[], missing = <MbReleaseGroup>[];
    for (final g in studio) {
      (localGroupIds.contains(g.id) || localKeys.contains(normalizeName(g.title)) ? owned : missing).add(g);
    }
    return (owned: owned, missing: missing);
  }
}
