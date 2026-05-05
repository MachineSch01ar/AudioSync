# AudioSync

AudioSync is a Discourse theme component that highlights the word currently being spoken in a topic post. It expects a narration audio file and a timestamp/alignment JSON file in the post content, then wraps matching words so playback can highlight them in real time.

It also lets readers click a highlighted word to seek the audio to that word.

AudioSync renders its own compact audio controls. The displayed duration comes from the timestamp JSON, not from browser MP3 metadata, so files with imperfect MP3 duration metadata can still show a stable reading timeline.

## Install

In Discourse, go to **Admin > Customize > Themes**, choose **Install**, and install this repository as a theme component from GitHub. Add the component to the active theme after installation.

Before publishing the repository publicly, update `about.json` with the final GitHub `about_url` and `license_url`.

## Topic Markup

Put the audio file and timestamp JSON link near the top of the topic or post:

```md
![narration|audio](https://example.com/audio/story.mp3)

[timestamps|attachment](https://example.com/audio/story.json)
```

AudioSync looks for these file extensions:

- Audio: `.mp3`, `.m4a`, `.wav`, `.ogg`, `.aac`
- Timestamps: `.json`

The component supports both Discourse-hosted uploads and external object storage URLs, as long as the browser can fetch the files.

## Timestamp JSON

AudioSync supports ElevenLabs-style character alignment JSON:

```json
{
  "alignment": {
    "characters": ["H", "e", "l", "l", "o"],
    "character_start_times_seconds": [0, 0.05, 0.1, 0.15, 0.2],
    "character_end_times_seconds": [0.05, 0.1, 0.15, 0.2, 0.25]
  }
}
```

It also supports word-level alignment arrays when present:

```json
{
  "alignment": {
    "words": [
      { "text": "Hello", "start": 0, "end": 0.25 }
    ]
  }
}
```

## External Storage And CORS

For S3-compatible storage, the JSON and audio URLs need to be readable by visitors. The JSON file must also allow browser `GET` requests from your Discourse origin, otherwise the component cannot fetch the timestamps.

A typical CORS rule for public audio/timestamp assets allows:

- Origin: your Discourse site URL
- Methods: `GET`, `HEAD`
- Headers: `*` or the headers your storage provider requires

## Settings

Admins can customize:

- `highlight_color`
- `highlight_text_color`
- `seek_preroll_seconds` defaults to `0.08`; increase it if clicked words start clipped
- `highlight_offset_seconds` defaults to `0.08`; increase it if highlights lag behind the audio, decrease it if highlights run ahead
- `debug_logging`

## Development

Useful files:

- `about.json`: Discourse theme component metadata
- `common/common.scss`: shared styles
- `javascripts/discourse/api-initializers/audio-sync.gjs`: post decoration and playback sync logic
- `settings.yml`: admin-configurable options
- `locales/en.yml`: component description and setting labels

For local Discourse theme development, the official `discourse_theme` CLI can watch this repository and sync changes to a development Discourse instance.
