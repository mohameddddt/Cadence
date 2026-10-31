/// SQL for the library database.
///
/// Rules for changing the schema (plan pitfall #10 - "No DB migrations"):
///  1. never edit [createStatements] in a way that differs from what earlier versions
///     produced without adding a [Migration] that brings old databases to the same shape;
///  2. bump [schemaVersion];
///  3. add a test in test/db_migration_test.dart.
const int schemaVersion = 2;

class Migration {
  const Migration({required this.from, required this.to, required this.statements});

  final int from;
  final int to;
  final List<String> statements;
}

/// Ordered list of upgrades.
const List<Migration> migrations = [
  // v2: playlists can have their own cover picture.
  Migration(from: 1, to: 2, statements: ['ALTER TABLE playlists ADD COLUMN cover_path TEXT']),
];

const List<String> createStatements = [
  '''
CREATE TABLE artists(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  sort_name TEXT,
  mb_artist_id TEXT,
  image_path TEXT,
  image_url TEXT,
  bio TEXT,
  bio_source TEXT,
  info_fetched_at INTEGER,
  followed INTEGER NOT NULL DEFAULT 0,
  last_release_check INTEGER
)''',
  'CREATE UNIQUE INDEX idx_artists_name ON artists(name COLLATE NOCASE)',
  'CREATE INDEX idx_artists_mbid ON artists(mb_artist_id)',
  '''
CREATE TABLE albums(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_key TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  artist_id INTEGER REFERENCES artists(id) ON DELETE SET NULL,
  artist_name TEXT,
  year INTEGER,
  mb_release_id TEXT,
  mb_release_group_id TEXT,
  cover_path TEXT,
  cover_source TEXT,
  compilation INTEGER NOT NULL DEFAULT 0
)''',
  'CREATE INDEX idx_albums_release ON albums(mb_release_id)',
  'CREATE INDEX idx_albums_artist ON albums(artist_id)',
  '''
CREATE TABLE tracks(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_path TEXT NOT NULL UNIQUE,
  content_uri TEXT,
  folder TEXT,
  title TEXT NOT NULL,
  artist_id INTEGER REFERENCES artists(id) ON DELETE SET NULL,
  artist_name TEXT,
  album_artist TEXT,
  album_id INTEGER REFERENCES albums(id) ON DELETE SET NULL,
  album_title TEXT,
  track_no INTEGER,
  disc_no INTEGER,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  year INTEGER,
  genre TEXT,
  bitrate INTEGER,
  format TEXT,
  size_bytes INTEGER NOT NULL DEFAULT 0,
  file_mtime INTEGER NOT NULL DEFAULT 0,
  date_added INTEGER NOT NULL,
  last_played INTEGER,
  play_count INTEGER NOT NULL DEFAULT 0,
  rating INTEGER NOT NULL DEFAULT 0,
  loved INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'local',
  source_url TEXT,
  mb_recording_id TEXT,
  mb_release_id TEXT,
  mb_release_group_id TEXT,
  mb_artist_id TEXT,
  acoustid TEXT,
  isrc TEXT,
  replay_gain_track REAL,
  replay_gain_album REAL,
  lyrics_id INTEGER,
  lyrics_offset_ms INTEGER NOT NULL DEFAULT 0,
  audio_hash TEXT,
  identify_state INTEGER NOT NULL DEFAULT 0,
  identify_score REAL,
  has_embedded_art INTEGER NOT NULL DEFAULT 0,
  missing INTEGER NOT NULL DEFAULT 0
)''',
  'CREATE INDEX idx_tracks_mb_recording ON tracks(mb_recording_id)',
  'CREATE INDEX idx_tracks_source_url ON tracks(source_url)',
  'CREATE INDEX idx_tracks_album ON tracks(album_id)',
  'CREATE INDEX idx_tracks_artist ON tracks(artist_id)',
  'CREATE INDEX idx_tracks_hash ON tracks(audio_hash)',
  'CREATE INDEX idx_tracks_added ON tracks(date_added)',
  'CREATE INDEX idx_tracks_played ON tracks(last_played)',
  'CREATE INDEX idx_tracks_folder ON tracks(folder)',
  '''
CREATE TABLE playlists(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  is_smart INTEGER NOT NULL DEFAULT 0,
  smart_rules TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  cover_path TEXT
)''',
  '''
CREATE TABLE playlist_tracks(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
  position INTEGER NOT NULL
)''',
  'CREATE INDEX idx_playlist_tracks ON playlist_tracks(playlist_id, position)',
  '''
CREATE TABLE lyrics(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  track_id INTEGER NOT NULL UNIQUE REFERENCES tracks(id) ON DELETE CASCADE,
  plain_text TEXT,
  synced_lrc TEXT,
  source TEXT,
  instrumental INTEGER NOT NULL DEFAULT 0,
  fetched_at INTEGER NOT NULL
)''',
  '''
CREATE TABLE download_jobs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  url TEXT NOT NULL,
  source_type TEXT NOT NULL,
  title TEXT,
  artist TEXT,
  thumbnail TEXT,
  status TEXT NOT NULL,
  progress REAL NOT NULL DEFAULT 0,
  stage TEXT,
  output_path TEXT,
  track_id INTEGER,
  error TEXT,
  log TEXT,
  created_at INTEGER NOT NULL,
  finished_at INTEGER,
  options TEXT
)''',
  'CREATE INDEX idx_jobs_status ON download_jobs(status)',
  'CREATE INDEX idx_jobs_url ON download_jobs(url)',
  '''
CREATE TABLE scrobble_queue(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  track_id INTEGER,
  artist TEXT NOT NULL,
  title TEXT NOT NULL,
  album TEXT,
  duration_ms INTEGER,
  mb_recording_id TEXT,
  timestamp INTEGER NOT NULL,
  lastfm_done INTEGER NOT NULL DEFAULT 0,
  lb_done INTEGER NOT NULL DEFAULT 0
)''',
  '''
CREATE TABLE api_cache(
  key TEXT PRIMARY KEY,
  response TEXT NOT NULL,
  expires_at INTEGER NOT NULL
)''',
  'CREATE INDEX idx_api_cache_expiry ON api_cache(expires_at)',
  '''
CREATE TABLE queue_items(
  position INTEGER PRIMARY KEY,
  json TEXT NOT NULL
)''',
  '''
CREATE TABLE wishlist(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  artist TEXT NOT NULL,
  title TEXT NOT NULL,
  album TEXT,
  isrc TEXT,
  origin TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  job_id INTEGER,
  created_at INTEGER NOT NULL
)''',
  '''
CREATE TABLE podcast_feeds(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  feed_url TEXT NOT NULL UNIQUE,
  image_url TEXT,
  author TEXT,
  last_checked INTEGER
)''',
  '''
CREATE TABLE radio_favorites(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  station_uuid TEXT,
  name TEXT NOT NULL,
  stream_url TEXT NOT NULL UNIQUE,
  favicon TEXT,
  country TEXT,
  tags TEXT
)''',
];

/// Full-text search. FTS4 is available in every Android SQLite build (FTS5 is not on
/// older releases), desktop test builds of SQLite may only ship FTS5, so the database
/// tries the modules in this order. Both are addressed through `rowid`.
const List<String> searchIndexStatements = [
  'CREATE VIRTUAL TABLE tracks_fts USING fts4(title, artist, album, tokenize=unicode61)',
  'CREATE VIRTUAL TABLE tracks_fts USING fts5(title, artist, album)',
];

const List<String> searchIndexTriggers = [
  '''
CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
  INSERT INTO tracks_fts(rowid, title, artist, album)
  VALUES (new.id, new.title, COALESCE(new.artist_name, ''), COALESCE(new.album_title, ''));
END''',
  '''
CREATE TRIGGER tracks_au AFTER UPDATE OF title, artist_name, album_title ON tracks BEGIN
  DELETE FROM tracks_fts WHERE rowid = old.id;
  INSERT INTO tracks_fts(rowid, title, artist, album)
  VALUES (new.id, new.title, COALESCE(new.artist_name, ''), COALESCE(new.album_title, ''));
END''',
  '''
CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
  DELETE FROM tracks_fts WHERE rowid = old.id;
END''',
];
