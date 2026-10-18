#!/usr/bin/env python3
"""Latency benchmark for a running wyoming-faster-whisper server.

Measures what Home Assistant's voice pipeline actually feels: time from
AudioStop to Transcript (server-side transcription latency). One fresh TCP
connection per run, exactly like HA's wyoming client does per utterance.

Usage: python3 bench.py <host> <port> <wav> [repeats]
Run inside a container that has the `wyoming` package:
  docker exec whisper-gpu python3 /data/bench.py 127.0.0.1 10300 /data/jfk.wav 5
"""
import asyncio, statistics, sys, time, wave

from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioStart, AudioStop, wav_to_chunks
from wyoming.event import async_read_event, async_write_event
from wyoming.info import Describe, Info

host, port, wav_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
repeats = int(sys.argv[4]) if len(sys.argv) > 4 else 5


async def one_run(show_info=False):
    reader, writer = await asyncio.open_connection(host, port)
    try:
        await async_write_event(Describe().event(), writer)
        while True:
            event = await asyncio.wait_for(async_read_event(reader), timeout=30)
            if event is not None and Info.is_type(event.type):
                if show_info:
                    for asr in Info.from_event(event).asr:
                        models = ",".join(getattr(m, "name", str(m)) for m in (asr.models or []))
                        print(f"service: {asr.name} models=[{models}]")
                break

        await async_write_event(Transcribe().event(), writer)
        with wave.open(wav_path, "rb") as w:
            audio_s = w.getnframes() / w.getframerate()
            await async_write_event(
                AudioStart(rate=w.getframerate(), width=w.getsampwidth(),
                           channels=w.getnchannels()).event(), writer)
            t0 = time.perf_counter()
            for chunk in wav_to_chunks(w, 1600):
                await async_write_event(chunk.event(), writer)
            await async_write_event(AudioStop().event(), writer)
            t_stop = time.perf_counter()
        while True:
            event = await asyncio.wait_for(async_read_event(reader), timeout=120)
            if event is not None and Transcript.is_type(event.type):
                t_end = time.perf_counter()
                return audio_s, t_end - t_stop, t_end - t0, Transcript.from_event(event).text
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def main():
    latencies, totals = [], []
    audio_s = 0.0
    for i in range(repeats):
        audio_s, lat, tot, text = await one_run(show_info=(i == 0))
        latencies.append(lat)
        totals.append(tot)
        tag = "cold" if i == 0 else f"warm{i}"
        print(f"  [{tag:>5}] stop->transcript {lat*1000:6.0f} ms | total {tot:5.2f} s | {text!r}")
    if len(latencies) > 1:
        warm = latencies[1:]
        print(f"RESULT warm n={len(warm)}: median {statistics.median(warm)*1000:.0f} ms "
              f"(min {min(warm)*1000:.0f} / max {max(warm)*1000:.0f}) | "
              f"audio {audio_s:.1f}s -> {audio_s/statistics.median(warm):.1f}x realtime")


asyncio.run(main())
