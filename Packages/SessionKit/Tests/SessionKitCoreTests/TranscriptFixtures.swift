// Synthetic fixtures (#2481): one three-cue conversation in each layout, from the format notes. No real
// meeting files are kept in the repository.
enum TranscriptFixtures {
    static let all: [String: String] = [
        "generic.srt": #"""
1
00:00:03,500 --> 00:00:06,000
Alice Example: Welcome everyone, let's start with the budget.

2
00:00:06,500 --> 00:00:09,000
Ben Sample: Thanks. I have the draft numbers ready.

3
00:00:09,500 --> 00:00:12,000
Alice Example: Great, please share them.
"""#,
        "meet.txt": #"""
Budget sync - 2026/03/04 10:00 GMT - Transcript

Attendees
Alice Example, Ben Sample

Transcript

00:00:03
Alice Example: Welcome everyone, let's start with the budget.

00:00:06
Ben Sample: Thanks. I have the draft numbers ready.

00:00:09
Alice Example: Great, please share them.
"""#,
        "otter.txt": #"""
Budget sync
Mar 4, 2026 10:00 AM

Alice Example  0:03
Welcome everyone, let's start with the budget.

Ben Sample  0:06
Thanks. I have the draft numbers ready.

Alice Example  0:09
Great, please share them.
"""#,
        "teams-docx.txt": #"""
Budget sync-20260304_100000-Meeting Recording
March 4, 2026, 10:00AM
1h 0m 0s

Alice Example started transcription

Alice Example   0 minutes 3 seconds
Welcome everyone, let's start with the budget.
Ben Sample   0 minutes 6 seconds
Thanks. I have the draft numbers ready.
Alice Example   0 minutes 9 seconds
Great, please share them.
"""#,
        "teams.vtt": #"""
WEBVTT

3f2a9c1e-1111-4a2b-9c3d-000000000001/12-0
00:00:03.500 --> 00:00:06.000
<v Alice Example>Welcome everyone, let's start with the budget.</v>

3f2a9c1e-1111-4a2b-9c3d-000000000001/13-0
00:00:06.500 --> 00:00:09.000
<v Ben Sample>Thanks. I have the draft numbers ready.</v>

3f2a9c1e-1111-4a2b-9c3d-000000000001/14-0
00:00:09.500 --> 00:00:12.000
<v Alice Example>Great, please share them.</v>
"""#,
        "webex.vtt": #"""
WEBVTT

1
00:00:03.500 --> 00:00:06.000
Alice Example: Welcome everyone, let's start with the budget.

2
00:00:06.500 --> 00:00:09.000
Ben Sample: Thanks. I have the draft numbers ready.

3
00:00:09.500 --> 00:00:12.000
Alice Example: Great, please share them.
"""#,
        "zoom-captions.txt": #"""
[Alice Example] 10:00:03
Welcome everyone, let's start with the budget.

[Ben Sample] 10:00:06
Thanks. I have the draft numbers ready.

[Alice Example] 10:00:09
Great, please share them.
"""#,
        "zoom.vtt": #"""
WEBVTT

1
00:00:03.500 --> 00:00:06.000
Alice Example: Welcome everyone, let's start with the budget.

2
00:00:06.500 --> 00:00:09.000
Ben Sample: Thanks. I have the draft numbers ready.

3
00:00:09.500 --> 00:00:12.000
Alice Example: Great, please share them.
"""#,
    ]
}
