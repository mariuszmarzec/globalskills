---
name: yt-dlp-downloader
description: Robust YouTube downloading and audio extraction via yt-dlp with anti-bot bypass flags (--user-agent, --extractor-args, --no-check-certificates) and oEmbed fallback search. Use when downloading videos or MP3s from YouTube URLs with yt-dlp to guarantee success.
---

# Skill: yt-dlp-downloader

## Purpose
Guarantees successful downloading and audio extraction from YouTube URLs using `yt-dlp` even when YouTube enforces bot detection or extraction warnings.

## Key Techniques for Success
1. **Anti-Bot Bypass Flags**: Always supply a realistic desktop User-Agent and appropriate extractor arguments to prevent "This video is not available" or bot detection errors:
   ```bash
   yt-dlp \
     --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36" \
     --extractor-args "youtube:player_client=android,web" \
     --no-check-certificates \
     -x --audio-format mp3 \
     -P nutki \
     "<URL>"
   ```
2. **oEmbed Fallback**: If a direct URL fails, retrieve the title via YouTube oEmbed API (`https://www.youtube.com/oembed?url=<URL>&format=json`), clean the title, and search via `ytsearch1:<title>` with the same robust flags.
3. **Duplicate Prevention**: Track already downloaded tracks or check existing file names/IDs in the destination folder before downloading.
