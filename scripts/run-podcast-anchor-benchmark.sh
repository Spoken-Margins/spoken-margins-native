#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_root="${TMPDIR:-/tmp}/spoken-margins-anchor-held-out-v2"
source_one="$cache_root/adventuresofsherlockhomes_04_conandoyle_64kb.mp3"
source_two="$cache_root/adventuresofsherlockhomes_05_conandoyle_64kb.mp3"
sender_audio="$cache_root/sender-edition.m4a"
inserted_audio="$cache_root/inserted-speech.m4a"
recipient_audio="$cache_root/recipient-edition.m4a"
sender_transcription_audio="$cache_root/sender-edition.wav"
recipient_transcription_audio="$cache_root/recipient-edition.wav"
whisper_model="$cache_root/ggml-base.en.bin"
sender_transcript_prefix="$cache_root/sender-transcript"
recipient_transcript_prefix="$cache_root/recipient-transcript"
sender_transcript="$sender_transcript_prefix.json"
recipient_transcript="$recipient_transcript_prefix.json"
result_path="$repo_root/artifacts/validation/sharing-next/podcast-anchor-benchmark-result.json"

for command_name in curl ffmpeg swift whisper-cli; do
    command -v "$command_name" >/dev/null || {
        echo "Required command is unavailable: $command_name" >&2
        exit 1
    }
done

mkdir -p "$cache_root" "$(dirname "$result_path")"

if [[ ! -s "$source_one" ]]; then
    curl -fL --retry 3 \
        "https://archive.org/download/the_adventures_of_sherlock_holmes_v5_1904_librivox/adventuresofsherlockhomes_04_conandoyle_64kb.mp3" \
        -o "$source_one"
fi
if [[ ! -s "$source_two" ]]; then
    curl -fL --retry 3 \
        "https://archive.org/download/the_adventures_of_sherlock_holmes_v5_1904_librivox/adventuresofsherlockhomes_05_conandoyle_64kb.mp3" \
        -o "$source_two"
fi

if [[ ! -s "$sender_audio" ]]; then
    ffmpeg -hide_banner -loglevel error -y -i "$source_one" -t 1200 \
        -vn -c:a aac -b:a 96k -ar 44100 -ac 1 "$sender_audio"
fi
if [[ ! -s "$inserted_audio" ]]; then
    ffmpeg -hide_banner -loglevel error -y -ss 420 -t 45 -i "$source_two" \
        -vn -c:a aac -b:a 96k -ar 44100 -ac 1 "$inserted_audio"
fi
if [[ ! -s "$recipient_audio" ]]; then
    ffmpeg -hide_banner -loglevel error -y \
        -i "$sender_audio" -i "$inserted_audio" \
        -filter_complex \
        "[0:a]atrim=start=0:end=240,asetpts=PTS-STARTPTS[s0];[1:a]atrim=start=0:end=45,asetpts=PTS-STARTPTS[ad];[0:a]atrim=start=240:end=480,asetpts=PTS-STARTPTS[s1];[0:a]atrim=start=500:end=700,asetpts=PTS-STARTPTS[s2];[0:a]atrim=start=100:end=140,asetpts=PTS-STARTPTS[repeat];[0:a]atrim=start=700:end=900,asetpts=PTS-STARTPTS[s3];[0:a]atrim=start=906:end=1200,asetpts=PTS-STARTPTS[s4];[s0][ad][s1][s2][repeat][s3][s4]concat=n=7:v=0:a=1[out]" \
        -map "[out]" -vn -c:a aac -b:a 80k -ar 48000 -ac 1 "$recipient_audio"
fi
if [[ ! -s "$whisper_model" ]]; then
    curl -fL --retry 3 \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
        -o "$whisper_model"
fi
if [[ ! -s "$sender_transcription_audio" ]]; then
    ffmpeg -hide_banner -loglevel error -y -i "$sender_audio" \
        -vn -c:a pcm_s16le -ar 16000 -ac 1 "$sender_transcription_audio"
fi
if [[ ! -s "$recipient_transcription_audio" ]]; then
    ffmpeg -hide_banner -loglevel error -y -i "$recipient_audio" \
        -vn -c:a pcm_s16le -ar 16000 -ac 1 "$recipient_transcription_audio"
fi
if [[ ! -s "$sender_transcript" ]]; then
    whisper-cli -m "$whisper_model" -f "$sender_transcription_audio" \
        -l en -t 8 -oj -np -of "$sender_transcript_prefix"
fi
if [[ ! -s "$recipient_transcript" ]]; then
    whisper-cli -m "$whisper_model" -f "$recipient_transcription_audio" \
        -l en -t 8 -oj -np -of "$recipient_transcript_prefix"
fi

SPOKEN_MARGINS_RUN_ANCHOR_CORPUS=1 \
SPOKEN_MARGINS_BENCHMARK_SENDER_AUDIO="$sender_audio" \
SPOKEN_MARGINS_BENCHMARK_RECIPIENT_AUDIO="$recipient_audio" \
SPOKEN_MARGINS_BENCHMARK_SENDER_TRANSCRIPT="$sender_transcript" \
SPOKEN_MARGINS_BENCHMARK_RECIPIENT_TRANSCRIPT="$recipient_transcript" \
SPOKEN_MARGINS_BENCHMARK_RESULT_PATH="$result_path" \
swift test --package-path "$repo_root/Packages/SessionKit" \
    --filter SharingTests/testHeldOutPublicDomainPodcastAnchorCorpus

echo "Benchmark result: $result_path"
