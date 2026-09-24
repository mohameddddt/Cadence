import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/library/library_health.dart';
import 'package:musicplayer/core/models/library_models.dart';

Artist artist(int id, String name) => Artist(id: id, name: name);
Album album(int id, String title, String? artist) => Album(id: id, title: title, groupKey: 'k$id', artistName: artist);

void main() {
  test('artistKey ignores case, accents, punctuation, spacing and a leading article', () {
    expect(artistKey('Beyoncé'), artistKey('beyonce'));
    expect(artistKey('AC/DC'), artistKey('AC DC'));
    expect(artistKey('The Beatles'), artistKey('Beatles'));
    expect(artistKey('  Sigur   Rós '), artistKey('Sigur Ros'));
    expect(artistKey('Björk'), isNot(artistKey('Bjork Guðmundsdóttir')));
  });

  test('foldDiacritics maps each accented letter to its own base letter', () {
    expect(foldDiacritics('àçéłñøřšťüýž'), 'acelnorstuyz');
    expect(foldDiacritics('Motörhead'), 'motorhead');
    expect(foldDiacritics('Mylène Farmer'), 'mylene farmer');
    expect(foldDiacritics('Łukasz'), 'lukasz');
  });

  test('duplicateArtistIds flags every member of a duplicate group and nothing else', () {
    final ids = duplicateArtistIds([artist(1, 'The Beatles'), artist(2, 'Beatles'), artist(3, 'Queen'), artist(4, 'AC/DC'), artist(5, 'AC DC')]);
    expect(ids, {1, 2, 4, 5});
  });

  test('duplicateAlbumIds needs the same title and the same artist', () {
    final ids = duplicateAlbumIds([album(1, 'Greatest Hits', 'Queen'), album(2, 'greatest hits', 'Queen'), album(3, 'Greatest Hits', 'ABBA'), album(4, 'Unique', null)]);
    expect(ids, {1, 2});
  });

  test('compare functions put duplicates next to each other', () {
    final list = [artist(1, 'Zed'), artist(2, 'AC DC'), artist(3, 'Yes'), artist(4, 'AC/DC')]..sort(compareArtistsByKey);
    expect(list.map((a) => a.id).toList().sublist(0, 2).toSet(), {2, 4});
  });

  test('formatTotalDuration picks a readable unit', () {
    expect(formatTotalDuration(48 * 60000), '48 min');
    expect(formatTotalDuration((12 * 60 + 5) * 60000), '12 h 5 min');
    expect(formatTotalDuration((3 * 24 + 4) * 3600 * 1000), '3 d 4 h');
  });
}
