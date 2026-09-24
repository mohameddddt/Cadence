package dev.personal.musicplayer;

import org.jaudiotagger.audio.AudioFile;
import org.jaudiotagger.audio.AudioFileIO;
import org.jaudiotagger.audio.AudioHeader;
import org.jaudiotagger.audio.flac.metadatablock.MetadataBlockDataPicture;
import org.jaudiotagger.tag.FieldKey;
import org.jaudiotagger.tag.Tag;
import org.jaudiotagger.tag.TagField;
import org.jaudiotagger.tag.TagOptionSingleton;
import org.jaudiotagger.tag.flac.FlacTag;
import org.jaudiotagger.tag.id3.AbstractID3v2Frame;
import org.jaudiotagger.tag.id3.AbstractID3v2Tag;
import org.jaudiotagger.tag.id3.framebody.FrameBodyTXXX;
import org.jaudiotagger.tag.images.AndroidArtwork;
import org.jaudiotagger.tag.mp4.field.Mp4TagReverseDnsField;
import org.jaudiotagger.tag.reference.ID3V2Version;
import org.jaudiotagger.tag.vorbiscomment.VorbisCommentTag;

import java.io.File;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Format-agnostic tag reader/writer built on jaudiotagger. It has no Android
 * dependencies on purpose so it can be exercised from a plain JVM.
 *
 * Field naming follows the MusicBrainz Picard tag mapping.
 */
public final class TagIO {
    private TagIO() {}

    static {
        Logger.getLogger("org.jaudiotagger").setLevel(Level.OFF);
        TagOptionSingleton o = TagOptionSingleton.getInstance();
        o.setAndroid(true);
        o.setID3V2Version(ID3V2Version.ID3_V24);
        o.setId3v1Save(false);
    }

    private static final String MP4_NS = "----:com.apple.iTunes:";
    private static final String ITUNES = "com.apple.iTunes";

    // Dart key -> jaudiotagger key for plain text fields.
    private static final Map<String, FieldKey> TEXT_KEYS = new HashMap<>();

    static {
        TEXT_KEYS.put("title", FieldKey.TITLE);
        TEXT_KEYS.put("artist", FieldKey.ARTIST);
        TEXT_KEYS.put("album", FieldKey.ALBUM);
        TEXT_KEYS.put("albumArtist", FieldKey.ALBUM_ARTIST);
        TEXT_KEYS.put("genre", FieldKey.GENRE);
        TEXT_KEYS.put("comment", FieldKey.COMMENT);
        TEXT_KEYS.put("lyrics", FieldKey.LYRICS);
        TEXT_KEYS.put("isrc", FieldKey.ISRC);
        TEXT_KEYS.put("date", FieldKey.YEAR);
        TEXT_KEYS.put("trackNo", FieldKey.TRACK);
        TEXT_KEYS.put("trackTotal", FieldKey.TRACK_TOTAL);
        TEXT_KEYS.put("discNo", FieldKey.DISC_NO);
        TEXT_KEYS.put("discTotal", FieldKey.DISC_TOTAL);
        TEXT_KEYS.put("mbRecordingId", FieldKey.MUSICBRAINZ_TRACK_ID);
        TEXT_KEYS.put("mbReleaseTrackId", FieldKey.MUSICBRAINZ_RELEASE_TRACK_ID);
        TEXT_KEYS.put("mbReleaseId", FieldKey.MUSICBRAINZ_RELEASEID);
        TEXT_KEYS.put("mbReleaseGroupId", FieldKey.MUSICBRAINZ_RELEASE_GROUP_ID);
        TEXT_KEYS.put("mbArtistId", FieldKey.MUSICBRAINZ_ARTISTID);
        TEXT_KEYS.put("acoustId", FieldKey.ACOUSTID_ID);
    }

    // Dart key -> free-form field name (TXXX / Vorbis comment / iTunes atom).
    private static final Map<String, String> CUSTOM_KEYS = new HashMap<>();

    static {
        CUSTOM_KEYS.put("replayGainTrack", "REPLAYGAIN_TRACK_GAIN");
        CUSTOM_KEYS.put("replayGainAlbum", "REPLAYGAIN_ALBUM_GAIN");
        CUSTOM_KEYS.put("sourceUrl", "SOURCE_URL");
    }

    // ------------------------------------------------------------------ read

    public static Map<String, Object> read(File file, String ext) throws Exception {
        AudioFile af = ext == null || ext.isEmpty() ? AudioFileIO.read(file) : AudioFileIO.readAs(file, ext);
        Map<String, Object> m = new HashMap<>();
        AudioHeader h = af.getAudioHeader();
        if (h != null) {
            m.put("durationMs", (long) (h.getPreciseTrackLength() * 1000));
            m.put("bitrate", h.getBitRateAsNumber());
            m.put("sampleRate", h.getSampleRateAsNumber());
            m.put("format", h.getFormat());
        }
        Tag tag = af.getTag();
        if (tag == null) return m;

        put(m, "title", first(tag, FieldKey.TITLE));
        put(m, "artist", first(tag, FieldKey.ARTIST));
        put(m, "album", first(tag, FieldKey.ALBUM));
        put(m, "albumArtist", first(tag, FieldKey.ALBUM_ARTIST));
        put(m, "genre", first(tag, FieldKey.GENRE));
        put(m, "comment", first(tag, FieldKey.COMMENT));
        put(m, "lyrics", first(tag, FieldKey.LYRICS));
        put(m, "isrc", first(tag, FieldKey.ISRC));
        put(m, "date", first(tag, FieldKey.YEAR));
        put(m, "trackNo", leadingInt(first(tag, FieldKey.TRACK)));
        put(m, "trackTotal", leadingInt(first(tag, FieldKey.TRACK_TOTAL)));
        put(m, "discNo", leadingInt(first(tag, FieldKey.DISC_NO)));
        put(m, "discTotal", leadingInt(first(tag, FieldKey.DISC_TOTAL)));
        put(m, "mbRecordingId", first(tag, FieldKey.MUSICBRAINZ_TRACK_ID));
        put(m, "mbReleaseTrackId", first(tag, FieldKey.MUSICBRAINZ_RELEASE_TRACK_ID));
        put(m, "mbReleaseId", first(tag, FieldKey.MUSICBRAINZ_RELEASEID));
        put(m, "mbReleaseGroupId", first(tag, FieldKey.MUSICBRAINZ_RELEASE_GROUP_ID));
        put(m, "mbArtistId", first(tag, FieldKey.MUSICBRAINZ_ARTISTID));
        put(m, "acoustId", first(tag, FieldKey.ACOUSTID_ID));
        for (Map.Entry<String, String> e : CUSTOM_KEYS.entrySet()) {
            put(m, e.getKey(), getCustom(tag, e.getValue()));
        }
        try {
            m.put("hasArt", !tag.getArtworkList().isEmpty());
        } catch (Throwable ignored) {
            m.put("hasArt", false);
        }
        return m;
    }

    // ----------------------------------------------------------------- write

    /**
     * Applies the given values. Absent keys are left alone, null/"" values delete the
     * field. {@code artFile} (a JPEG/PNG) replaces the embedded picture when non-null;
     * {@code clearArt} removes it.
     */
    public static void write(File file, String ext, Map<String, Object> values, File artFile, boolean clearArt)
            throws Exception {
        AudioFile af = ext == null || ext.isEmpty() ? AudioFileIO.read(file) : AudioFileIO.readAs(file, ext);
        Tag tag = af.getTagOrCreateAndSetDefault();

        for (Map.Entry<String, FieldKey> e : TEXT_KEYS.entrySet()) {
            if (!values.containsKey(e.getKey())) continue;
            String v = asString(values.get(e.getKey()));
            try {
                if (v == null || v.isEmpty()) {
                    tag.deleteField(e.getValue());
                } else {
                    tag.setField(e.getValue(), v);
                }
            } catch (UnsupportedOperationException | org.jaudiotagger.tag.KeyNotFoundException ignored) {
                // Field not representable in this container (e.g. MBIDs in RIFF INFO).
            }
        }
        for (Map.Entry<String, String> e : CUSTOM_KEYS.entrySet()) {
            if (!values.containsKey(e.getKey())) continue;
            try {
                setCustom(tag, e.getValue(), asString(values.get(e.getKey())));
            } catch (RuntimeException ignored) {
                // Free-form fields are not available in every container.
            }
        }
        if (clearArt) {
            try {
                tag.deleteArtworkField();
            } catch (Exception ignored) {
            }
        }
        if (artFile != null) {
            byte[] bytes = Files.readAllBytes(artFile.toPath());
            try {
                setArt(tag, bytes, sniffMime(bytes));
            } catch (UnsupportedOperationException ignored) {
                // e.g. RIFF/WAV INFO cannot carry pictures
            }
        }
        af.commit();
    }

    // -------------------------------------------------------------- helpers

    /**
     * jaudiotagger's AndroidArtwork cannot decode images (setImageFromData throws), which
     * the FLAC/Vorbis writers call, so build those picture blocks by hand.
     */
    private static void setArt(Tag tag, byte[] bytes, String mime) throws Exception {
        if (tag instanceof FlacTag) {
            int[] wh = imageSize(bytes);
            FlacTag f = (FlacTag) tag;
            f.deleteArtworkField();
            f.setField(new MetadataBlockDataPicture(bytes, 3, mime, "", wh[0], wh[1], 24, 0));
        } else if (tag instanceof VorbisCommentTag) {
            VorbisCommentTag v = (VorbisCommentTag) tag;
            v.deleteArtworkField();
            v.setArtworkField(bytes, mime);
        } else {
            AndroidArtwork art = new AndroidArtwork();
            art.setBinaryData(bytes);
            art.setMimeType(mime);
            art.setPictureType(3); // front cover
            art.setDescription("");
            try {
                tag.deleteArtworkField();
            } catch (Exception ignored) {
            }
            tag.setField(art);
        }
    }

    /** Reads width/height from a JPEG or PNG header without decoding the image. */
    static int[] imageSize(byte[] b) {
        try {
            if (b.length > 24 && (b[0] & 0xFF) == 0x89 && b[1] == 'P') {
                int w = ((b[16] & 0xFF) << 24) | ((b[17] & 0xFF) << 16) | ((b[18] & 0xFF) << 8) | (b[19] & 0xFF);
                int h = ((b[20] & 0xFF) << 24) | ((b[21] & 0xFF) << 16) | ((b[22] & 0xFF) << 8) | (b[23] & 0xFF);
                return new int[] {w, h};
            }
            int i = 2;
            while (i + 9 < b.length) {
                if ((b[i] & 0xFF) != 0xFF) {
                    i++;
                    continue;
                }
                int marker = b[i + 1] & 0xFF;
                if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
                    int h = ((b[i + 5] & 0xFF) << 8) | (b[i + 6] & 0xFF);
                    int w = ((b[i + 7] & 0xFF) << 8) | (b[i + 8] & 0xFF);
                    return new int[] {w, h};
                }
                int len = ((b[i + 2] & 0xFF) << 8) | (b[i + 3] & 0xFF);
                i += 2 + len;
            }
        } catch (RuntimeException ignored) {
        }
        return new int[] {0, 0};
    }

    private static String sniffMime(byte[] b) {
        if (b.length > 4 && (b[0] & 0xFF) == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return "image/png";
        return "image/jpeg";
    }

    private static String asString(Object o) {
        if (o == null) return null;
        return o.toString().trim();
    }

    private static void put(Map<String, Object> m, String k, Object v) {
        if (v != null) m.put(k, v);
    }

    private static String first(Tag tag, FieldKey key) {
        try {
            String s = tag.getFirst(key);
            if (s == null) return null;
            s = s.trim();
            return s.isEmpty() ? null : s;
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer leadingInt(String s) {
        if (s == null) return null;
        int i = 0;
        while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
        if (i == 0) return null;
        try {
            return Integer.parseInt(s.substring(0, i));
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static Tag unwrap(Tag tag) {
        if (tag instanceof FlacTag) return ((FlacTag) tag).getVorbisCommentTag();
        return tag;
    }

    static String getCustom(Tag tag, String name) {
        try {
            Tag t = unwrap(tag);
            if (t instanceof AbstractID3v2Tag) {
                List<TagField> frames = t.getFields("TXXX");
                for (TagField f : frames) {
                    if (f instanceof AbstractID3v2Frame
                            && ((AbstractID3v2Frame) f).getBody() instanceof FrameBodyTXXX) {
                        FrameBodyTXXX b = (FrameBodyTXXX) ((AbstractID3v2Frame) f).getBody();
                        if (name.equalsIgnoreCase(b.getDescription())) {
                            String v = b.getText();
                            return v == null || v.trim().isEmpty() ? null : v.trim();
                        }
                    }
                }
                return null;
            }
            String v;
            if (t instanceof VorbisCommentTag) {
                v = t.getFirst(name);
            } else {
                v = t.getFirst(MP4_NS + name);
            }
            return v == null || v.trim().isEmpty() ? null : v.trim();
        } catch (Throwable e) {
            return null;
        }
    }

    static void setCustom(Tag tag, String name, String value) throws Exception {
        Tag t = unwrap(tag);
        boolean delete = value == null || value.isEmpty();
        if (t instanceof AbstractID3v2Tag) {
            AbstractID3v2Tag id3 = (AbstractID3v2Tag) t;
            List<TagField> keep = new ArrayList<>();
            boolean had = false;
            for (TagField f : id3.getFields("TXXX")) {
                if (f instanceof AbstractID3v2Frame
                        && ((AbstractID3v2Frame) f).getBody() instanceof FrameBodyTXXX
                        && name.equalsIgnoreCase(((FrameBodyTXXX) ((AbstractID3v2Frame) f).getBody()).getDescription())) {
                    had = true;
                } else {
                    keep.add(f);
                }
            }
            if (had) {
                id3.removeFrame("TXXX");
                for (TagField f : keep) id3.addField(f);
            }
            if (!delete) {
                AbstractID3v2Frame frame = id3.createFrame("TXXX");
                FrameBodyTXXX body = new FrameBodyTXXX();
                body.setDescription(name);
                body.setText(value);
                frame.setBody(body);
                id3.addField(frame);
            }
        } else if (t instanceof VorbisCommentTag) {
            if (delete) t.deleteField(name);
            else ((VorbisCommentTag) t).setField(name, value);
        } else {
            String id = MP4_NS + name;
            if (delete) {
                t.deleteField(id);
            } else {
                t.setField(new Mp4TagReverseDnsField(id, ITUNES, name, value));
            }
        }
    }
}
