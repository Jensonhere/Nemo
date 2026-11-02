#!/usr/bin/env python3
"""Export Tencent Cloud TTS audio with the same VoiceType used by the app."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import ssl
import sys
import time
import uuid
import urllib.error
import urllib.request
from pathlib import Path


SERVICE = "tts"
HOST = "tts.tencentcloudapi.com"
ENDPOINT = f"https://{HOST}"
API_VERSION = "2019-08-23"
DEFAULT_VOICE_TYPE = 101028


def sha256_hex(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def hmac_sha256(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def tc3_authorization(
    *,
    secret_id: str,
    secret_key: str,
    timestamp: int,
    payload: bytes,
) -> str:
    date = time.strftime("%Y-%m-%d", time.gmtime(timestamp))
    canonical_headers = (
        "content-type:application/json; charset=utf-8\n"
        f"host:{HOST}\n"
    )
    signed_headers = "content-type;host"
    canonical_request = "\n".join(
        [
            "POST",
            "/",
            "",
            canonical_headers,
            signed_headers,
            sha256_hex(payload),
        ]
    )

    credential_scope = f"{date}/{SERVICE}/tc3_request"
    string_to_sign = "\n".join(
        [
            "TC3-HMAC-SHA256",
            str(timestamp),
            credential_scope,
            sha256_hex(canonical_request),
        ]
    )

    secret_date = hmac_sha256(("TC3" + secret_key).encode("utf-8"), date)
    secret_service = hmac_sha256(secret_date, SERVICE)
    secret_signing = hmac_sha256(secret_service, "tc3_request")
    signature = hmac.new(
        secret_signing, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    return (
        "TC3-HMAC-SHA256 "
        f"Credential={secret_id}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, "
        f"Signature={signature}"
    )


def read_text(args: argparse.Namespace) -> str:
    if args.text_file:
        return Path(args.text_file).read_text(encoding="utf-8").strip()
    if args.text:
        return args.text.strip()
    raise SystemExit("Provide --text or --text-file.")


def request_tts(args: argparse.Namespace, text: str) -> bytes:
    secret_id = args.secret_id or os.environ.get("TENCENT_TTS_SECRET_ID")
    secret_key = args.secret_key or os.environ.get("TENCENT_TTS_SECRET_KEY")
    if not secret_id or not secret_key:
        raise SystemExit(
            "Missing Tencent credentials. Set TENCENT_TTS_SECRET_ID and "
            "TENCENT_TTS_SECRET_KEY, or pass --secret-id/--secret-key."
        )

    params = {
        "Text": text,
        "SessionId": args.session_id or uuid.uuid4().hex,
        "VoiceType": args.voice_type,
        "Codec": args.codec,
        "SampleRate": args.sample_rate,
        "Speed": args.speed,
        "Volume": args.volume,
        "PrimaryLanguage": args.primary_language,
        "ModelType": args.model_type,
    }
    payload = json.dumps(
        params, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    timestamp = int(time.time())
    headers = {
        "Authorization": tc3_authorization(
            secret_id=secret_id,
            secret_key=secret_key,
            timestamp=timestamp,
            payload=payload,
        ),
        "Content-Type": "application/json; charset=utf-8",
        "Host": HOST,
        "X-TC-Action": "TextToVoice",
        "X-TC-Version": API_VERSION,
        "X-TC-Timestamp": str(timestamp),
        "X-TC-Region": args.region,
    }

    req = urllib.request.Request(
        ENDPOINT, data=payload, headers=headers, method="POST"
    )
    context = ssl.create_default_context()
    if hasattr(ssl, "TLSVersion"):
        context.minimum_version = ssl.TLSVersion.TLSv1_2

    last_error: Exception | None = None
    for attempt in range(1, args.retries + 1):
        try:
            with urllib.request.urlopen(
                req, timeout=args.timeout, context=context
            ) as resp:
                raw = resp.read().decode("utf-8")
            break
        except urllib.error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="replace")
            raise SystemExit(f"Tencent TTS HTTP {exc.code}: {details}") from exc
        except urllib.error.URLError as exc:
            last_error = exc
            if attempt < args.retries:
                time.sleep(min(2 * attempt, 6))
    else:
        reason = getattr(last_error, "reason", last_error)
        if isinstance(reason, ssl.SSLError) and "UNEXPECTED_EOF" in str(reason):
            raise SystemExit(
                "Tencent TTS TLS connection was closed before any API response. "
                "This is usually a network/proxy/certificate interception issue, "
                "not a TTS text or VoiceType problem. Try PowerShell checks: "
                "`Test-NetConnection tts.tencentcloudapi.com -Port 443` and "
                "`Invoke-WebRequest https://tts.tencentcloudapi.com`."
            ) from last_error
        raise SystemExit(f"Tencent TTS request failed: {last_error}") from last_error

    data = json.loads(raw)
    response = data.get("Response", {})
    if "Error" in response:
        error = response["Error"]
        raise SystemExit(
            f"Tencent TTS error {error.get('Code')}: {error.get('Message')}"
        )

    audio_b64 = response.get("Audio")
    if not audio_b64:
        raise SystemExit(f"Tencent TTS response has no Audio field: {raw}")
    return base64.b64decode(audio_b64)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate an audio file from Tencent Cloud TTS."
    )
    parser.add_argument("--text", help="Text to synthesize.")
    parser.add_argument("--text-file", help="UTF-8 text file to synthesize.")
    parser.add_argument(
        "--out",
        default=f"exports/tencent_tts_{DEFAULT_VOICE_TYPE}.mp3",
        help="Output audio path.",
    )
    parser.add_argument(
        "--voice-type",
        type=int,
        default=DEFAULT_VOICE_TYPE,
        help="Tencent Cloud VoiceType. App default is 101028.",
    )
    parser.add_argument("--codec", choices=["mp3", "wav"], default="mp3")
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--speed", type=float, default=0.0)
    parser.add_argument("--volume", type=float, default=0.0)
    parser.add_argument("--primary-language", type=int, default=1)
    parser.add_argument("--model-type", type=int, default=1)
    parser.add_argument("--region", default=os.environ.get("TENCENT_TTS_REGION", "ap-shanghai"))
    parser.add_argument("--session-id")
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--secret-id", help="Prefer TENCENT_TTS_SECRET_ID env var.")
    parser.add_argument("--secret-key", help="Prefer TENCENT_TTS_SECRET_KEY env var.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    text = read_text(args)
    if not text:
        raise SystemExit("Text is empty.")

    audio = request_tts(args, text)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(audio)
    print(f"Wrote {out_path} ({len(audio)} bytes), voiceType={args.voice_type}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
