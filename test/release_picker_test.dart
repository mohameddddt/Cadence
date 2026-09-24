import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/features/metadata/musicbrainz_models.dart';
import 'package:musicplayer/features/metadata/release_picker.dart';

MbRelease rel(
  String id, {
  String? status = 'Official',
  String? type = 'Album',
  List<String> secondary = const [],
  String? date,
  String? country,
  List<String> formats = const ['CD'],
}) =>
    MbRelease(
      id: id,
      title: id,
      status: status,
      primaryType: type,
      secondaryTypes: secondary,
      date: date,
      country: country,
      formats: formats,
    );

void main() {
  const picker = ReleasePicker(preferredCountry: 'GB');

  test('empty list has no best release', () => expect(picker.pick(const []), isNull));

  test('official beats promotion and bootleg regardless of anything else', () {
    final best = picker.pick([
      rel('bootleg', status: 'Bootleg', date: '1990'),
      rel('promo', status: 'Promotion', date: '1991'),
      rel('official', status: 'Official', type: 'Single', date: '2005'),
    ]);
    expect(best!.id, 'official');
  });

  test('album beats EP beats single beats compilation', () {
    final best = picker.pick([
      rel('single', type: 'Single', date: '1970'),
      rel('comp', type: 'Album', secondary: ['Compilation'], date: '1971'),
      rel('ep', type: 'EP', date: '1972'),
      rel('album', type: 'Album', date: '1980'),
    ]);
    expect(best!.id, 'album');
    expect(picker.rank([rel('a', type: 'Single'), rel('b', type: 'EP')]).map((r) => r.id), ['b', 'a']);
  });

  test('earliest year wins between equal albums', () {
    final best = picker.pick([
      rel('reissue', date: '2011-05-01', country: 'GB'),
      rel('original', date: '1975-10-31', country: 'US'),
    ]);
    expect(best!.id, 'original');
  });

  test('preferred country breaks ties, then worldwide', () {
    final best = picker.pick([
      rel('us', date: '2000', country: 'US'),
      rel('gb', date: '2000', country: 'GB'),
      rel('ww', date: '2000', country: 'XW'),
    ]);
    expect(best!.id, 'gb');
    expect(picker.rank([rel('us', date: '2000', country: 'US'), rel('ww', date: '2000', country: 'XW')]).first.id, 'ww');
  });

  test('digital/CD is preferred over vinyl when everything else is equal', () {
    final best = picker.pick([
      rel('vinyl', date: '2000', country: 'GB', formats: ['12" Vinyl']),
      rel('cd', date: '2000', country: 'GB', formats: ['CD']),
    ]);
    expect(best!.id, 'cd');
  });

  test('missing date sorts after a known year', () {
    final best = picker.pick([rel('nodate'), rel('dated', date: '2019')]);
    expect(best!.id, 'dated');
  });

  test('final tie is broken by the full date', () {
    final best = picker.pick([
      rel('later', date: '2000-06-01', country: 'GB'),
      rel('earlier', date: '2000-01-01', country: 'GB'),
    ]);
    expect(best!.id, 'earlier');
  });

  test('parses a recording JSON with releases (real MusicBrainz shape)', () {
    final rec = MbRecording.fromJson({
      'id': 'rec1',
      'title': 'Song',
      'length': 200000,
      'artist-credit': [
        {'name': 'A', 'joinphrase': ' & ', 'artist': {'id': 'a1', 'name': 'A'}},
        {'name': 'B', 'joinphrase': '', 'artist': {'id': 'b1', 'name': 'B'}},
      ],
      'isrcs': ['ISRC1'],
      'releases': [
        {
          'id': 'rel1',
          'title': 'Album',
          'status': 'Official',
          'date': '2001-02-03',
          'country': 'US',
          'release-group': {'id': 'rg1', 'primary-type': 'Album', 'secondary-types': []},
          'media': [
            {'position': 1, 'format': 'CD', 'track-count': 12, 'tracks': [{'id': 'tr1', 'number': '5', 'title': 'Song'}]},
          ],
        }
      ],
    });
    expect(rec.artistCredit, 'A & B');
    expect(rec.artists.map((a) => a.id), ['a1', 'b1']);
    final r = rec.releases.single;
    expect(r.year, 2001);
    expect(r.releaseGroupId, 'rg1');
    expect(r.trackNumber, 5);
    expect(r.discNumber, 1);
    expect(r.totalTracksOnDisc, 12);
    expect(r.releaseTrackId, 'tr1');
    expect(r.formats, ['CD']);
  });
}
