#!/usr/bin/env python3
"""Real-model prompt-cache check: MODEL=/path/model.gguf [GHOSTPEN=/path/ghostpen] python3 tests/e2e-llm-cache.py."""
import json
import os
import selectors
import subprocess
import tempfile
import time


def receive(process, timeout=180):
    ready = selectors.DefaultSelector()
    try:
        ready.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not ready.select(max(0, deadline - time.monotonic())):
                break
            line = process.stdout.readline()
            if not line:
                raise RuntimeError(f"runner exited: {process.poll()}")
            try:
                return json.loads(line)
            except ValueError:
                continue
        raise TimeoutError("runner response timed out")
    finally:
        ready.close()


def request(process, number, text):
    payload = dict(id=number, cmd="chat", system="Answer the request briefly using the provided facts. Output only the answer.",
                   user=text, max_tokens=40, temperature=0, think=False)
    process.stdin.write((json.dumps(payload) + "\n").encode())
    process.stdin.flush()
    answer = ""
    while True:
        result = receive(process)
        if "error" in result:
            raise RuntimeError(result["error"])
        answer += result.get("delta", "")
        if result.get("done"):
            return answer, result


def main():
    model = os.environ["MODEL"]
    executable = os.path.expanduser(os.environ.get("GHOSTPEN", "~/.local/bin/ghostpen"))
    with tempfile.TemporaryFile(mode="w+") as log:
        process = subprocess.Popen([executable, "--llm-helper", "--model", model, "--ctx", "8192"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                                   bufsize=0)
        try:
            assert receive(process).get("ready"), "runner did not become ready"
            facts = "The access code is ORCHID.\n" + "We reviewed the project timeline and confirmed the delivery plan.\n" * 350
            first, cold = request(process, 1, facts + "\nRequest: What is the access code?")
            second, warm = request(process, 2, facts + "\nRequest: Repeat the access code only.")
            # A short, unrelated action must not invalidate or corrupt the checkpoint.
            request(process, 3, "Request: Reply with OK.")
            third, restored = request(process, 4, facts + "\nRequest: Give the access code again.")
            for answer in (first, second, third):
                assert "ORCHID" in answer.upper(), repr(answer)
            log.seek(0)
            assert "prompt cache:" in log.read(), "no prompt prefix was reused"
            print(json.dumps({"cold_prompt_ms": cold["prompt_ms"], "followup_prompt_ms": warm["prompt_ms"],
                              "after_unrelated_action_prompt_ms": restored["prompt_ms"],
                              "prompt_tokens": cold["prompt_tokens"], "answers_correct": True}))
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
