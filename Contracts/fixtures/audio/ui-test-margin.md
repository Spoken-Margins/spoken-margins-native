# UI-test Margin audio

`ui-test-margin.mp3` is a 160,128-byte extract of the existing synthetic
`evidence-length-48k-stereo.mp3`: 417 already encoded MPEG-1 Layer III frames,
starting after its ID3 tag and Info frame. At 48 kHz, this is 10.008 seconds.
No encoder, microphone, speech service or network is used to create it.
It contains synthetic audio, not a person's spoken Margin.

The opt-in UI-test recorder copies it into `SpokenMargins/interjections/`.
The offline podcast seed repeats the frames twelve times into `PodcastAudio/`
(120.096 seconds). Only the small fixture is committed; runtime copies remain
in the UI-test app's container. The fixture is not a Git LFS file.
