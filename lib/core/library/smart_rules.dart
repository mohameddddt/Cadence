import 'dart:convert';

/// Sort orders shared by the library screens and smart playlists.
enum TrackSort {
  title('t.title COLLATE NOCASE'),
  artist('t.artist_name COLLATE NOCASE, t.album_title COLLATE NOCASE, t.disc_no, t.track_no'),
  album('t.album_title COLLATE NOCASE, t.disc_no, t.track_no, t.title COLLATE NOCASE'),
  dateAdded('t.date_added'),
  lastPlayed('t.last_played'),
  playCount('t.play_count'),
  duration('t.duration_ms'),
  year('t.year'),
  random('RANDOM()');

  const TrackSort(this.sql);
  final String sql;

  static TrackSort parse(String? s) =>
      TrackSort.values.firstWhere((e) => e.name == s, orElse: () => TrackSort.title);
}

enum SmartField {
  title('t.title', _Kind.text),
  artist('t.artist_name', _Kind.text),
  album('t.album_title', _Kind.text),
  genre('t.genre', _Kind.text),
  source('t.source', _Kind.text),
  format('t.format', _Kind.text),
  year('t.year', _Kind.number),
  playCount('t.play_count', _Kind.number),
  rating('t.rating', _Kind.number),
  bitrate('t.bitrate', _Kind.number),
  durationSec('(t.duration_ms / 1000)', _Kind.number),
  lastPlayed('t.last_played', _Kind.date),
  dateAdded('t.date_added', _Kind.date),
  loved('t.loved', _Kind.flag),
  identified('(t.identify_state = 1)', _Kind.flag);

  const SmartField(this.column, this._kind);
  final String column;
  final _Kind _kind;

  bool get isText => _kind == _Kind.text;
  bool get isNumber => _kind == _Kind.number;
  bool get isDate => _kind == _Kind.date;
  bool get isFlag => _kind == _Kind.flag;

  static SmartField parse(String? s) =>
      SmartField.values.firstWhere((e) => e.name == s, orElse: () => SmartField.title);
}

enum _Kind { text, number, date, flag }

enum SmartOp {
  contains,
  notContains,
  equals,
  notEquals,
  startsWith,
  greaterThan,
  lessThan,
  withinDays, // date >= now - N days
  notWithinDays, // never or older than N days
  isTrue,
  isFalse;

  static SmartOp parse(String? s) => SmartOp.values.firstWhere((e) => e.name == s, orElse: () => SmartOp.contains);
}

class SmartCondition {
  const SmartCondition(this.field, this.op, [this.value = '']);

  final SmartField field;
  final SmartOp op;
  final String value;

  Map<String, dynamic> toJson() => {'field': field.name, 'op': op.name, 'value': value};

  factory SmartCondition.fromJson(Map<String, dynamic> j) => SmartCondition(
        SmartField.parse(j['field'] as String?),
        SmartOp.parse(j['op'] as String?),
        (j['value'] ?? '').toString(),
      );
}

/// A saved query. Stored as JSON in playlists.smart_rules and evaluated on demand,
/// so the playlist always reflects the current library.
class SmartRules {
  const SmartRules({
    this.matchAll = true,
    this.conditions = const [],
    this.sort = TrackSort.title,
    this.descending = false,
    this.limit,
  });

  final bool matchAll;
  final List<SmartCondition> conditions;
  final TrackSort sort;
  final bool descending;
  final int? limit;

  factory SmartRules.parse(String? json) {
    if (json == null || json.isEmpty) return const SmartRules();
    final m = jsonDecode(json) as Map<String, dynamic>;
    return SmartRules(
      matchAll: (m['matchAll'] as bool?) ?? true,
      conditions: ((m['conditions'] as List?) ?? const [])
          .map((e) => SmartCondition.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      sort: TrackSort.parse(m['sort'] as String?),
      descending: (m['descending'] as bool?) ?? false,
      limit: m['limit'] as int?,
    );
  }

  String toJson() => jsonEncode({
        'matchAll': matchAll,
        'conditions': conditions.map((c) => c.toJson()).toList(),
        'sort': sort.name,
        'descending': descending,
        'limit': limit,
      });

  /// Builds `SELECT t.* FROM tracks t WHERE ... ORDER BY ... LIMIT ...`.
  ///
  /// [nowSeconds] is injectable so date rules are testable.
  ({String sql, List<Object?> args}) toQuery({required int nowSeconds}) {
    final args = <Object?>[];
    final parts = <String>[];
    for (final c in conditions) {
      final clause = _clause(c, args, nowSeconds);
      if (clause != null) parts.add(clause);
    }
    final glue = matchAll ? ' AND ' : ' OR ';
    final where = parts.isEmpty ? '1' : '(${parts.join(glue)})';
    final order = sort == TrackSort.random ? 'RANDOM()' : '${sort.sql} ${descending ? 'DESC' : 'ASC'}';
    final lim = limit == null ? '' : ' LIMIT ${limit!.clamp(1, 100000)}';
    return (sql: 'SELECT t.* FROM tracks t WHERE t.missing = 0 AND $where ORDER BY $order$lim', args: args);
  }

  String? _clause(SmartCondition c, List<Object?> args, int now) {
    final col = c.field.column;
    final v = c.value.trim();
    switch (c.op) {
      case SmartOp.contains:
        args.add('%${_escapeLike(v)}%');
        return "$col LIKE ? ESCAPE '\\'";
      case SmartOp.notContains:
        args.add('%${_escapeLike(v)}%');
        return "($col IS NULL OR $col NOT LIKE ? ESCAPE '\\')";
      case SmartOp.startsWith:
        args.add('${_escapeLike(v)}%');
        return "$col LIKE ? ESCAPE '\\'";
      case SmartOp.equals:
        if (c.field.isText) {
          args.add(v);
          return '$col = ? COLLATE NOCASE';
        }
        final n = num.tryParse(v);
        if (n == null) return null;
        args.add(n);
        return '$col = ?';
      case SmartOp.notEquals:
        if (c.field.isText) {
          args.add(v);
          return '($col IS NULL OR $col != ? COLLATE NOCASE)';
        }
        final n = num.tryParse(v);
        if (n == null) return null;
        args.add(n);
        return '($col IS NULL OR $col != ?)';
      case SmartOp.greaterThan:
        final n = num.tryParse(v);
        if (n == null) return null;
        args.add(n);
        return '$col > ?';
      case SmartOp.lessThan:
        final n = num.tryParse(v);
        if (n == null) return null;
        args.add(n);
        return '$col < ?';
      case SmartOp.withinDays:
        final d = int.tryParse(v);
        if (d == null) return null;
        args.add(now - d * 86400);
        return '($col IS NOT NULL AND $col >= ?)';
      case SmartOp.notWithinDays:
        final d = int.tryParse(v);
        if (d == null) return null;
        args.add(now - d * 86400);
        return '($col IS NULL OR $col < ?)';
      case SmartOp.isTrue:
        return '$col != 0';
      case SmartOp.isFalse:
        return '$col = 0';
    }
  }

  static String _escapeLike(String s) => s.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');

  /// A few ready-made playlists shown in the "new smart playlist" sheet.
  static const Map<String, SmartRules> presets = {
    'Recently added': SmartRules(
      conditions: [SmartCondition(SmartField.dateAdded, SmartOp.withinDays, '30')],
      sort: TrackSort.dateAdded,
      descending: true,
      limit: 100,
    ),
    'Most played': SmartRules(
      conditions: [SmartCondition(SmartField.playCount, SmartOp.greaterThan, '0')],
      sort: TrackSort.playCount,
      descending: true,
      limit: 50,
    ),
    'Never played': SmartRules(
      conditions: [SmartCondition(SmartField.playCount, SmartOp.equals, '0')],
      sort: TrackSort.dateAdded,
      descending: true,
    ),
    'Loved': SmartRules(
      conditions: [SmartCondition(SmartField.loved, SmartOp.isTrue)],
      sort: TrackSort.title,
    ),
    'Needs tagging': SmartRules(
      conditions: [SmartCondition(SmartField.identified, SmartOp.isFalse)],
      sort: TrackSort.dateAdded,
      descending: true,
    ),
  };
}
