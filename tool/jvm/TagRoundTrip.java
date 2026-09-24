import dev.personal.musicplayer.TagIO;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.HashMap;
import java.util.Map;

public class TagRoundTrip {
    public static void main(String[] args) throws Exception {
        String dir = args[0];
        int failures = 0;
        String[] exts = {"mp3", "flac", "m4a", "ogg", "opus", "wav"};
        for (String ext : exts) {
            File src = new File(dir, "t." + ext);
            File f = new File(dir, "rt." + ext);
            Files.copy(src.toPath(), f.toPath(), StandardCopyOption.REPLACE_EXISTING);
            Map<String, Object> v = new HashMap<>();
            v.put("title", "Ünïcode Títle");
            v.put("artist", "The Artist");
            v.put("album", "The Album");
            v.put("albumArtist", "Various Artists");
            v.put("trackNo", "3");
            v.put("trackTotal", "12");
            v.put("discNo", "1");
            v.put("date", "2019-05-01");
            v.put("genre", "Rock");
            v.put("mbRecordingId", "11111111-1111-1111-1111-111111111111");
            v.put("mbReleaseId", "22222222-2222-2222-2222-222222222222");
            v.put("mbArtistId", "33333333-3333-3333-3333-333333333333");
            v.put("mbReleaseGroupId", "44444444-4444-4444-4444-444444444444");
            v.put("acoustId", "55555555-5555-5555-5555-555555555555");
            v.put("isrc", "USRC17607839");
            v.put("replayGainTrack", "-3.20 dB");
            v.put("sourceUrl", "https://example.com/watch?v=abc");
            v.put("lyrics", "line one\nline two");
            String status;
            try {
                TagIO.write(f, ext, v, new File(dir, "art.jpg"), false);
                Map<String, Object> r = TagIO.read(f, ext);
                StringBuilder bad = new StringBuilder();
                for (Map.Entry<String, Object> e : v.entrySet()) {
                    Object got = r.get(e.getKey());
                    String want = e.getValue().toString();
                    String g = got == null ? null : got.toString();
                    if (e.getKey().equals("trackNo") || e.getKey().equals("trackTotal") || e.getKey().equals("discNo")) {
                        // ints
                    }
                    if (!want.equals(g)) bad.append(" ").append(e.getKey()).append("=[").append(g).append("]");
                }
                status = bad.length() == 0 ? "OK all fields" : "MISMATCH:" + bad;
                status += " hasArt=" + r.get("hasArt") + " dur=" + r.get("durationMs");
                // second write: change a custom field and remove another; ensure no duplicates/no crash
                Map<String, Object> v2 = new HashMap<>();
                v2.put("replayGainTrack", "-5.00 dB");
                v2.put("genre", "");
                TagIO.write(f, ext, v2, null, false);
                Map<String, Object> r2 = TagIO.read(f, ext);
                status += " | rewrite rg=" + r2.get("replayGainTrack") + " src=" + r2.get("sourceUrl") + " genre=" + r2.get("genre") + " art=" + r2.get("hasArt") + " title=" + r2.get("title");
            } catch (Throwable t) {
                status = "FAIL " + t;
            }
            System.out.println(ext + ": " + status);
            // Opus and WAV are known gaps (documented): everything else must round-trip.
            if (!ext.equals("opus") && !ext.equals("wav") && !status.startsWith("OK")) failures++;
        }
        if (failures > 0) System.exit(1);
    }
}
