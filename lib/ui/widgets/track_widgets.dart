import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_services.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../features/playback/media_items.dart';
import '../screens/album_screen.dart';
import '../screens/artist_screen.dart';
import '../screens/identify_screens.dart';
import '../screens/lyrics_sheet.dart';
import '../screens/tag_editor_screen.dart';
import 'common.dart';
import 'cover_art.dart';

/// One song row: art, title, "artist - album", duration, overflow menu.
class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.current = false,
    this.playing = false,
    this.showArt = true,
    this.trailing,
    this.subtitleOverride,
    this.playlistId,
    this.playlistEntryId,
    this.leadingNumber,
  });

  final Track track;
  final VoidCallback onTap;
  final bool current;
  final bool playing;
  final bool showArt;
  final Widget? trailing;
  final String? subtitleOverride;
  final int? playlistId;
  final int? playlistEntryId;

  /// Shows "3" instead of artwork (album track lists).
  final int? leadingNumber;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = current ? t.colorScheme.primary : null;
    final unidentified = track.identifyState == IdentifyState.needsReview;
    return ListTile(
      onTap: onTap,
      onLongPress: () => showTrackMenu(context, track, playlistId: playlistId, playlistEntryId: playlistEntryId),
      leading: leadingNumber != null
          ? SizedBox(width: 40, child: Center(child: current ? Icon(playing ? Icons.graphic_eq : Icons.pause, color: color) : Text('$leadingNumber', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))))
          : showArt
              ? Stack(alignment: Alignment.center, children: [
                  CoverArt(track: track, size: 48),
                  if (current) Container(width: 48, height: 48, decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: Icon(playing ? Icons.graphic_eq : Icons.pause, color: Colors.white)),
                ])
              : null,
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: current ? FontWeight.w700 : null)),
      subtitle: Text(
        subtitleOverride ?? '${track.displayArtist}${track.albumTitle == null ? '' : '  •  ${track.albumTitle}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing ??
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (unidentified) Tooltip(message: 'Possible tag match waiting for review', child: Icon(Icons.auto_fix_high, size: 18, color: t.colorScheme.tertiary)),
            if (track.loved) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.favorite, size: 16, color: t.colorScheme.error)),
            const SizedBox(width: 6),
            Text(formatMs(track.durationMs), style: t.textTheme.bodySmall),
            IconButton(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert),
              onPressed: () => showTrackMenu(context, track, playlistId: playlistId, playlistEntryId: playlistEntryId),
            ),
          ]),
    );
  }
}

/// A scrollable list of tracks that knows what is playing. Tapping a row plays the list
/// from that row.
class TrackListView extends StatelessWidget {
  const TrackListView({super.key, required this.tracks, this.controller, this.padding, this.playlistId, this.entryIds, this.header, this.showArt = true, this.numbered = false, this.shrinkWrap = false, this.physics});

  final List<Track> tracks;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;
  final int? playlistId;

  /// playlist_tracks row ids in list order (for removing single entries).
  final List<int>? entryIds;
  final Widget? header;
  final bool showArt;
  final bool numbered;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    return StreamBuilder<MediaItem?>(
      stream: services.player.currentItem,
      builder: (context, item) {
        final currentId = item.data?.trackId;
        return StreamBuilder(
          stream: services.player.state,
          builder: (context, st) {
            final playing = st.data?.playing ?? false;
            final offset = header == null ? 0 : 1;
            return ListView.builder(
              controller: controller,
              padding: padding,
              shrinkWrap: shrinkWrap,
              physics: physics,
              itemCount: tracks.length + offset,
              itemExtent: null,
              itemBuilder: (context, i) {
                if (header != null && i == 0) return header!;
                final index = i - offset;
                final t = tracks[index];
                return TrackTile(
                  key: ValueKey('${t.id}-$index'),
                  track: t,
                  current: t.id == currentId,
                  playing: playing,
                  showArt: showArt,
                  leadingNumber: numbered ? (t.trackNo ?? index + 1) : null,
                  playlistId: playlistId,
                  playlistEntryId: entryIds != null && index < entryIds!.length ? entryIds![index] : null,
                  onTap: () {
                    if (t.id == currentId) {
                      services.player.toggle();
                    } else {
                      services.player.playTracks(tracks, index: index);
                    }
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Bottom-sheet with everything you can do to a track.
Future<void> showTrackMenu(BuildContext context, Track track, {int? playlistId, int? playlistEntryId}) {
  final services = context.read<AppServices>();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) {
      Future<void> run(Future<void> Function() f) async {
        Navigator.pop(sheet);
        await f();
      }

      void push(Widget page) {
        Navigator.pop(sheet);
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: CoverArt(track: track, size: 48),
              title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(track.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            ListTile(leading: const Icon(Icons.playlist_play), title: const Text('Play next'), onTap: () => run(() async {
                  await services.player.playNext([track]);
                  if (context.mounted) showSnack(context, 'Playing next');
                })),
            ListTile(leading: const Icon(Icons.queue_music), title: const Text('Add to queue'), onTap: () => run(() async {
                  await services.player.enqueue([track]);
                  if (context.mounted) showSnack(context, 'Added to queue');
                })),
            ListTile(leading: const Icon(Icons.playlist_add), title: const Text('Add to playlist…'), onTap: () {
              Navigator.pop(sheet);
              showAddToPlaylistSheet(context, [track]);
            }),
            if (playlistId != null && playlistEntryId != null)
              ListTile(leading: const Icon(Icons.remove_circle_outline), title: const Text('Remove from this playlist'), onTap: () => run(() => services.repo.removeFromPlaylist(playlistId, playlistEntryId))),
            ListTile(
              leading: Icon(track.loved ? Icons.favorite : Icons.favorite_border),
              title: Text(track.loved ? 'Remove from favourites' : 'Add to favourites'),
              onTap: () => run(() async {
                await services.repo.setLoved(track.id, !track.loved);
                if (services.lastFm.canScrobble && track.artistName != null) {
                  try {
                    await services.lastFm.love(track.artistName!, track.title, love: !track.loved);
                  } on Object {
                    // offline: the local flag is what matters
                  }
                }
              }),
            ),
            if (track.albumId != null) ListTile(leading: const Icon(Icons.album), title: const Text('Go to album'), onTap: () => push(AlbumScreen(albumId: track.albumId!))),
            if (track.artistId != null) ListTile(leading: const Icon(Icons.person), title: const Text('Go to artist'), onTap: () => push(ArtistScreen(artistId: track.artistId!))),
            ListTile(leading: const Icon(Icons.lyrics_outlined), title: const Text('Lyrics'), onTap: () {
              Navigator.pop(sheet);
              showLyricsSheet(context, track);
            }),
            ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Edit tags'), onTap: () => push(TagEditorScreen(track: track))),
            ListTile(leading: const Icon(Icons.auto_fix_high), title: const Text('Identify (fix tags)'), onTap: () => push(IdentifyReviewScreen(track: track))),
            ListTile(leading: const Icon(Icons.info_outline), title: const Text('Details'), onTap: () {
              Navigator.pop(sheet);
              showTrackDetails(context, track);
            }),
            if (track.hasRealPath)
              ListTile(leading: const Icon(Icons.share_outlined), title: const Text('Share file'), onTap: () => run(() => SharePlus.instance.share(ShareParams(files: [XFile(track.filePath)], text: '${track.title} - ${track.displayArtist}')))),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('Delete from device', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(sheet);
                _confirmDelete(context, track);
              },
            ),
          ]),
        ),
      );
    },
  );
}

Future<void> _confirmDelete(BuildContext context, Track track) async {
  final services = context.read<AppServices>();
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Delete this song?'),
      content: Text('"${track.title}" will be removed from your device. This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    final uri = track.contentUri ?? track.filePath;
    await services.bridges.mediaStore.deleteAudio(uri);
    await services.repo.deleteTracks([track.id]);
    if (context.mounted) showSnack(context, 'Deleted');
  } on Object catch (e) {
    if (context.mounted) showSnack(context, 'Could not delete: $e');
  }
}

Future<void> showTrackDetails(BuildContext context, Track t) {
  Widget row(String k, String? v) => v == null || v.isEmpty
      ? const SizedBox.shrink()
      : Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 110, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))), Expanded(child: SelectableText(v))]));
  return showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(t.title),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          row('Artist', t.artistName),
          row('Album', t.albumTitle),
          row('Duration', formatMs(t.durationMs)),
          row('Format', '${t.format ?? '?'}${t.bitrate == null ? '' : ' · ${t.bitrate} kbps'}'),
          row('Size', formatBytes(t.sizeBytes)),
          row('Source', t.source.label),
          row('Source URL', t.sourceUrl),
          row('Path', t.filePath),
          row('MB recording', t.mbRecordingId),
          row('MB release', t.mbReleaseId),
          row('AcoustID', t.acoustId),
          row('ReplayGain', t.replayGainTrack == null ? null : '${t.replayGainTrack!.toStringAsFixed(2)} dB'),
          row('Plays', '${t.playCount}'),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
    ),
  );
}

/// Pick (or create) a playlist and add [tracks] to it.
Future<void> showAddToPlaylistSheet(BuildContext context, List<Track> tracks) {
  final services = context.read<AppServices>();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: FutureBuilder<List<Playlist>>(
        future: services.repo.playlists(),
        builder: (context, snap) {
          final lists = (snap.data ?? const <Playlist>[]).where((p) => !p.isSmart).toList();
          return ListView(shrinkWrap: true, children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New playlist'),
              onTap: () async {
                final name = await promptText(context, title: 'New playlist', hint: 'Name');
                if (name == null) return;
                final id = await services.repo.createPlaylist(name);
                await services.repo.addToPlaylist(id, tracks.map((t) => t.id));
                if (sheet.mounted) Navigator.pop(sheet);
                if (context.mounted) showSnack(context, 'Added to "$name"');
              },
            ),
            for (final p in lists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(p.name),
                subtitle: Text('${p.trackCount} songs'),
                onTap: () async {
                  await services.repo.addToPlaylist(p.id, tracks.map((t) => t.id));
                  if (sheet.mounted) Navigator.pop(sheet);
                  if (context.mounted) showSnack(context, 'Added to "${p.name}"');
                },
              ),
          ]);
        },
      ),
    ),
  );
}

/// Small text prompt dialog.
Future<String?> promptText(BuildContext context, {required String title, String? hint, String? initial, String confirm = 'OK'}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: hint), onSubmitted: (v) => Navigator.pop(d, v.trim().isEmpty ? null : v.trim())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text.trim().isEmpty ? null : c.text.trim()), child: Text(confirm)),
      ],
    ),
  );
}
