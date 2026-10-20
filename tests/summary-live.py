#!/usr/bin/env python3
"""Replay the captured Summary request against an installed E4B (macOS/Linux).

No downloads or settings changes. The Zig fixture test checks that this request
still matches web_page.summaryPrompt(.standard). --record retains raw helper
events for comparing the producer's actual initial channel with the answer.
"""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True, help="built GhostPen executable")
    parser.add_argument("--model", type=Path, required=True, help="installed Gemma E4B GGUF")
    parser.add_argument("--cpu", action="store_true", help="request the runner's CPU mode")
    parser.add_argument("--thinking", action="store_true", help="request thinking and verify both channels are returned")
    parser.add_argument("--record", type=Path, help="save raw helper JSONL, including output")
    args = parser.parse_args()
    fixture = json.loads((Path(__file__).resolve().parents[1] / "src/fixtures/summary-gemma4-e4b.json").read_text())
    request = {**fixture["formatted_request"], "think": args.thinking}
    command = [str(args.exe.resolve()), "--llm-helper", "--model", str(args.model.resolve()), "--ctx", "4096"]
    if args.cpu:
        command.append("--cpu")
    events, chunks = [], []
    producer = completion = None
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
    selector = selectors.DefaultSelector()
    try:
        # Bound startup and generation, and always reap the runner on failure.
        deadline = time.monotonic() + 15 * 60
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b""
        while completion is None:
            if not selector.select(max(0, deadline - time.monotonic())):
                raise RuntimeError("Timed out waiting for E4B")
            data = os.read(process.stdout.fileno(), 65536)
            if not data:
                raise RuntimeError("Model runner exited before completing the request")
            pending += data
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                event = json.loads(line)
                events.append(event)
                if event.get("ready"):
                    process.stdin.write((json.dumps(request) + "\n").encode())
                if "initial_thinking" in event:
                    producer = event
                if "delta" in event:
                    chunks.append(event["delta"])
                if "error" in event:
                    raise RuntimeError(event["error"])
                if event.get("done"):
                    completion = event
        output = "".join(chunks)
        assert producer and producer["format"] == "gemma4" and producer["initial_thinking"] is args.thinking, producer
        assert not completion["cancelled"] and not completion["truncated"], completion
        # These assertions belong to this controlled regression fixture, not
        # to production filtering of arbitrary article headings or prose.
        if args.thinking:
            thinking, separator, answer = output.partition("<channel|>")
            assert separator and thinking.strip() and answer.strip(), "Missing thinking/answer boundary"
        else:
            assert not output.lstrip().startswith("Thinking Process:"), "Original reasoning preamble reproduced"
            assert "<channel|>" not in output and "<|channel>thought" not in output, "Unexpected thought-channel output"
            answer = output
        # Substring checks accept malformed '- ## Details' list items. Verify
        # the block structure the reader actually needs, in both thinking modes.
        assert re.search(r"^## Key points\s*$", answer, re.MULTILINE), "Key points must be a top-level heading"
        assert re.search(r"^## Details\s*$", answer, re.MULTILINE), "Details must be a top-level heading"
        assert not re.search(r"^\s*[-*+]\s+#{1,6}\s", answer, re.MULTILINE), "A heading was nested in a list"
        points = answer.split("## Key points", 1)[1].split("## Details", 1)[0]
        assert re.search(r"^[-*+]\s+\S", points, re.MULTILINE), "Key points must contain bullet items"
        print(json.dumps({"passed": True, "producer": producer, "completion": completion, "output_chars": len(output)}, indent=2))
    finally:
        selector.close()
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if args.record:
            args.record.write_text("".join(json.dumps(event, ensure_ascii=False) + "\n" for event in events))


if __name__ == "__main__":
    main()
