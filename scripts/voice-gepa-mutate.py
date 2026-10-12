#!/usr/bin/env python3
"""GEPA mutator: rewrite a voice prompt from its failures, via the AI gateway.

Reads a JSON request on stdin:

    {"instructions": "...", "model": "google/gemini-3.8-flash", "count": 3,
     "failures": [{"text": "hello", "reply": "How can I help you today?",
                   "expect": "", "forbid": ["how can i help"]}]}

and prints `{"variants": [{"name": "...", "instructions": "..."}]}`.

This is the reflective step of `scripts/voice-gepa.sh`: the lab scores prompts
against a labelled corpus, this rewrites the best one using the turns it failed,
and the loop keeps whichever rewrite scores higher. The corpus is the objective,
so a corpus of real calls is worth more than one written from rules — see
`docs/voice-prompt-lab.md`.
"""

import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("GEPA_URL", "https://ai-gateway.vercel.sh/v1/chat/completions")
TIMEOUT_S = float(os.environ.get("GEPA_TIMEOUT_S", "120"))

SYSTEM = """\
You improve the `instructions` of a voice agent. The caller hears the reply \
spoken aloud, so the agent's own words are the whole interface.

You are given the current instructions and the turns it failed. Rewrite the \
instructions so those failures stop, without losing what already works.

Rules for the instructions you write:
- They are the agent's prompt, not a commentary: no references to tests, the \
corpus, or these instructions.
- Plain spoken-reply rules only. Keep them short and concrete.
- Never name a specific caller question or a specific answer.
- Keep the agent's persona: it is the agent the caller reached, never a voice \
layer, router, or middleware. It never asks the caller what to forward.
- Fix the failure by stating the rule the reply broke, not by banning words.

Reply with JSON only:
{"variants": [{"name": "short-slug", "instructions": "<full replacement text>"}]}"""


def build_user(request):
    lines = ["Current instructions:", request["instructions"].strip(), ""]
    failures = request.get("failures") or []
    if failures:
        lines.append("Turns it failed:")
        for failure in failures:
            lines.append(f"- caller: {failure.get('text', '')!r}")
            lines.append(f"  replied: {failure.get('reply', '')!r}")
            if failure.get("expect"):
                lines.append(f"  the reply must contain: {failure['expect']!r}")
            forbid = failure.get("forbid") or []
            if forbid:
                lines.append("  the reply must not contain: " + ", ".join(repr(b) for b in forbid))
    else:
        lines.append("No failures recorded: vary the wording while keeping the same rules.")
    lines.append("")
    lines.append(f"Write {int(request.get('count', 3))} distinct variants.")
    return "\n".join(lines)


def extract_json(text):
    """The model may fence the JSON or wrap it in prose."""
    text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    start, end = text.find("{"), text.rfind("}")
    if start >= 0 and end > start:
        return json.loads(text[start : end + 1])
    raise SystemExit(f"mutator: no JSON in the model reply: {text[:200]!r}")


def main():
    request = json.load(sys.stdin)
    key = os.environ.get("AI_GATEWAY_API_KEY", "")
    if not key:
        raise SystemExit("mutator: AI_GATEWAY_API_KEY is not set")
    body = json.dumps(
        {
            "model": request.get("model") or "google/gemini-3.8-flash",
            "messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": build_user(request)},
            ],
            # Generous: a reasoning model spends most of this on thinking and
            # returns an empty content when it runs out.
            "max_tokens": 4000,
        }
    ).encode()
    http = urllib.request.Request(
        URL,
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(http, timeout=TIMEOUT_S) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f"mutator: gateway {error.code}: {error.read()[:400]!r}")
    message = payload["choices"][0]["message"]
    content = message.get("content") or ""
    if not content.strip():
        raise SystemExit(f"mutator: empty reply (finish={payload['choices'][0].get('finish_reason')!r})")
    variants = extract_json(content).get("variants") or []
    variants = [
        {"name": str(v.get("name") or f"variant-{i + 1}"), "instructions": str(v.get("instructions") or "").strip()}
        for i, v in enumerate(variants)
    ]
    variants = [v for v in variants if v["instructions"]]
    if not variants:
        raise SystemExit(f"mutator: no usable variants in: {content[:200]!r}")
    print(json.dumps({"variants": variants}))


if __name__ == "__main__":
    main()
