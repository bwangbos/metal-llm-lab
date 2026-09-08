"""Managed MTPLX adapter. Importing this module never imports MLX.

The stock Python distribution remains unmodified. The launch-time ASGI boundary
enforces native prompting and the requested vision capability before inference.
"""
import argparse
import asyncio
import base64
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request

MODEL_ID = "qwen3.8-flash-next-mtplx"
RUNTIME_ID = "mtplx-2.11.2"
REVISION = "6bc2f6e8426ccb4af73c81bc56ba7718afc92cc6"
ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def json_sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def safe_path(path):
    path = Path(path).absolute()
    for component in (path, *path.parents):
        if str(component) in ("/var", "/tmp") and component.resolve() == Path("/private" + str(component)):
            continue  # macOS system-owned aliases, not user-controlled escapes.
        require(not component.is_symlink(), "unsafe symlink in managed path")
    return path


def atomic_json(path, value):
    safe_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, sort_keys=True, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_model(model):
    require(model["schema_version"] == 3 and model["id"] == MODEL_ID and
            model["runtime_type"] == "mtplx" and model["runtime_id"] == RUNTIME_ID,
            "invalid MTPLX model identity")
    require(model["revision"] == REVISION, "model revision must match pinned snapshot")
    require(model["max_context"] == 262144 and model["default_profile"] == "default" and
            model["profiles"] == [{"id": "default", "context": 262144, "mtp_policy": "on", "status": "pending-acceptance"}],
            "invalid MTPLX profiles")
    require(model["license_url"].startswith(model["repository"] + "/blob/" + REVISION + "/"), "unpinned model license")
    seen = set()
    for artifact in model["artifacts"]:
        name = artifact["filename"]
        require(re.fullmatch(r"[A-Za-z0-9_.-]+", name) and name not in (".", "..") and name not in seen,
                "unsafe or duplicate artifact filename")
        seen.add(name)
        require(type(artifact["bytes"]) is int and artifact["bytes"] >= 0 and
                re.fullmatch(r"[a-f0-9]{64}", artifact["sha256"]), "invalid artifact digest or size")
        require(artifact["url"] == model["repository"] + "/resolve/" + REVISION + "/" + name,
                "artifact source does not match pinned revision")
    required = {"config.json", "tokenizer.json", "chat_template.jinja", "model.safetensors.index.json",
                "mtp.safetensors", "model-vision.safetensors", "ngram-table.safetensors", "LICENSE", ".gitattributes", ".metadata_never_index",
                "README-upstream-qwen.md", "README.md", "generation_config.json", "merges.txt", "mtplx_runtime.json",
                "preprocessor_config.json", "processor_config.json", "tokenizer_config.json", "video_preprocessor_config.json", "vocab.json"}
    required.update(f"model-{i:05d}-of-00019.safetensors" for i in range(1, 20))
    require(required == seen,
            "incomplete MTPLX snapshot manifest")


def validate_runtime(runtime, root=None):
    root = ROOT if root is None else root
    require(runtime["schema_version"] == 2 and runtime["runtime_type"] == "mtplx" and
            runtime["id"] == RUNTIME_ID and runtime["version"] == "2.11.2" and runtime["python"] == "3.12",
            "invalid MTPLX runtime identity")
    require(runtime["lock"] == "manifests/locks/mtplx-2.11.2-macos-arm64-py312.txt", "unsafe runtime lock path")
    lock = root / runtime["lock"]
    require(digest(lock) == runtime["lock_sha256"], "runtime lock checksum mismatch")
    text = lock.read_text().replace("\\\n", "")
    pins = {}
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        match = re.fullmatch(r"([a-z0-9-]+)==([0-9][A-Za-z0-9.]*)\s+((?:--hash=sha256:[a-f0-9]{64}\s*)+)", line)
        require(match is not None, "lock contains unpinned or unhashed dependency")
        require(match[1] not in pins, "duplicate dependency")
        pins[match[1]] = match[2]
    require(pins == {p["name"]: p["version"] for p in runtime["packages"]} and
            pins.get("llguidance") == "1.8.0" and pins.get("mtplx") == "2.11.2", "lock dependency mismatch")
    require(runtime["capabilities"] == {"serve": True, "api_bench": True, "local_bench": False},
            "invalid runtime capabilities")


def load_manifests(root=None):
    root = ROOT if root is None else root
    model = json.loads((root / "manifests/models" / (MODEL_ID + ".json")).read_text())
    runtime = json.loads((root / "manifests/runtimes" / (RUNTIME_ID + ".json")).read_text())
    validate_model(model)
    validate_runtime(runtime, root)
    return model, runtime


def fingerprint(path):
    safe_path(path)
    info = path.stat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.getuid() and
            not info.st_mode & 0o022, "artifact must be an owned, non-shared regular file")
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def check_file(path, artifact):
    before = fingerprint(path)
    require(before[2] == artifact["bytes"], "artifact byte count mismatch: " + artifact["filename"])
    require(digest(path) == artifact["sha256"], "artifact checksum mismatch: " + artifact["filename"])
    require(before == fingerprint(path), "artifact changed during verification")
    return before


def verify_snapshot(directory, artifacts, mode, receipt_path, binding, write=True):
    require(mode in ("cached", "full"), "artifact check must be cached or full")
    safe_path(directory)
    cached = {}
    if mode == "cached" and receipt_path.exists():
        try:
            fingerprint(receipt_path)
            receipt = json.loads(receipt_path.read_text())
            if receipt.get("binding") == binding:
                cached = receipt["files"]
        except (ValueError, KeyError, OSError):
            pass
    files, hits, hashes = {}, 0, 0
    for artifact in artifacts:
        path = directory / artifact["filename"]
        current = fingerprint(path)
        entry = {"fingerprint": current, "sha256": artifact["sha256"], "bytes": artifact["bytes"]}
        if current[2] == artifact["bytes"] and cached.get(artifact["filename"]) == entry:
            hits += 1
        else:
            entry["fingerprint"] = check_file(path, artifact)
            hashes += 1
        files[artifact["filename"]] = entry
    receipt = {"schema_version": 1, "binding": binding, "files": files}
    if write:
        atomic_json(receipt_path, receipt)
    return {"requested_mode": mode, "effective_mode": "mixed" if hits and hashes else "cached" if hits else "full",
            "cache_hits": hits, "cache_misses": hashes if mode == "cached" else 0,
            "full_hashes": hashes, "receipt_set_sha256": json_sha(receipt)}


def install_snapshot(directory, artifacts, source=None):
    safe_path(directory)
    if source is not None:
        safe_path(source)
        require(source.resolve() != directory.resolve(), "import source must differ from managed destination")
        # Preflight every source before copying; preserve source bytes and metadata.
        for artifact in artifacts:
            check_file(source / artifact["filename"], artifact)
    directory.mkdir(parents=True, exist_ok=True)
    verified = {}
    for artifact in artifacts:
        target = safe_path(directory / artifact["filename"])
        partial = safe_path(directory / (artifact["filename"] + ".part"))
        if target.exists():
            verified[artifact["filename"]] = {"fingerprint": check_file(target, artifact), "sha256": artifact["sha256"], "bytes": artifact["bytes"]}
            continue
        if source is not None:
            require(not partial.exists(), "import partial already exists; verify/resume download or remove it explicitly")
            with (source / artifact["filename"]).open("rb") as incoming, partial.open("xb") as outgoing:
                shutil.copyfileobj(incoming, outgoing, 8 * 1024 * 1024)
        else:
            offset = fingerprint(partial)[2] if partial.exists() else 0
            require(offset <= artifact["bytes"], "partial artifact exceeds expected byte count")
            if artifact["bytes"] == 0 and not partial.exists():
                partial.touch(exist_ok=False)
            if offset < artifact["bytes"]:
                headers = {"Range": f"bytes={offset}-"} if offset else {}
                if os.environ.get("HF_TOKEN"):
                    headers["Authorization"] = "Bearer " + os.environ["HF_TOKEN"]
                request = urllib.request.Request(artifact["url"], headers=headers)
                with urllib.request.urlopen(request, timeout=60) as response:
                    if offset:
                        require(response.status == 206 and response.headers.get("Content-Range", "").startswith(f"bytes {offset}-"),
                                "server did not honor download resume range; partial preserved")
                    with partial.open("ab" if offset else "xb") as output:
                        shutil.copyfileobj(response, output, 8 * 1024 * 1024)
        check_file(partial, artifact)
        # Link refuses a concurrent replacement, unlike an overwriting rename.
        os.link(partial, target)
        partial.unlink()
        verified[artifact["filename"]] = {"fingerprint": fingerprint(target), "sha256": artifact["sha256"], "bytes": artifact["bytes"]}
    return verified


def setup_snapshot(directory, artifacts, mode, receipt_path, binding, source=None):
    safe_path(directory)
    if source is not None:
        safe_path(source)
        for artifact in artifacts:
            check_file(source / artifact["filename"], artifact)
    existing = [a for a in artifacts if (directory / a["filename"]).exists()]
    missing = [a for a in artifacts if a not in existing]
    checked = verify_snapshot(directory, existing, mode, receipt_path, binding)
    entries = json.loads(receipt_path.read_text())["files"]
    entries.update(install_snapshot(directory, missing, source=source))
    receipt = {"schema_version": 1, "binding": binding, "files": entries}
    atomic_json(receipt_path, receipt)
    hits, hashes = checked["cache_hits"], checked["full_hashes"] + len(missing)
    return {"requested_mode": mode, "effective_mode": "mixed" if hits and hashes else "cached" if hits else "full",
            "cache_hits": hits, "cache_misses": checked["cache_misses"] + len(missing) if mode == "cached" else 0,
            "full_hashes": hashes, "receipt_set_sha256": json_sha(receipt)}


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="metal-llm MTPLX")
    parser.add_argument("command", choices=("setup", "serve", "bench", "launch", "validate-model", "validate-runtime", "validate-identity", "validate-result"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--artifact-check", choices=("cached", "full"), default="cached")
    for name in ("profile", "mtp", "context", "vision", "runtime", "import-from", "suite", "mode", "identity", "file"):
        parser.add_argument("--" + name)
    parser.add_argument("--yes", action="store_true")
    require(len([v for v in argv if v.startswith("--")]) == len(set(v.split("=")[0] for v in argv if v.startswith("--"))),
            "duplicate options are not supported")
    return parser.parse_args(argv)


def resolve_config(args, model, env, chip, memory):
    require(not env.get("METAL_LLM_CONTEXT"), "METAL_LLM_CONTEXT was removed; use --profile custom --mtp on|off --context TOKENS")
    require(args.runtime is None, "MTPLX rejects --runtime; runtime is fixed by package")
    profile = args.profile or "default"
    require(profile in ("default", "custom"), "MTPLX profiles are default or custom")
    if profile == "custom":
        require(args.mtp in ("on", "off") and args.context is not None,
                "custom requires --mtp on|off and --context; dynamic is unsupported")
        require(re.fullmatch(r"[0-9]+", args.context), "context must be a positive integer")
        context, mtp = int(args.context), args.mtp
    else:
        require(args.mtp is None and args.context is None, "default rejects --mtp and --context; use --profile custom")
        context, mtp = 262144, "on"
    require(0 < context <= model["max_context"], "context exceeds model maximum or is not positive")
    require(args.vision in (None, "on", "off"), "vision must be on or off")
    require(env.get("METAL_LLM_PARALLEL", "1") == "1", "MTPLX supports concurrency one only (METAL_LLM_PARALLEL=1)")
    port = env.get("METAL_LLM_PORT", "8080")
    require(re.fullmatch(r"[0-9]+", port) and 1 <= int(port) <= 65535, "invalid METAL_LLM_PORT")
    host = env.get("METAL_LLM_HOST", "127.0.0.1")
    require(host and not any(c.isspace() for c in host), "invalid METAL_LLM_HOST")
    require(host in ("127.0.0.1", "localhost", "::1") or env.get("METAL_LLM_API_KEY"), "non-localhost serving requires METAL_LLM_API_KEY")
    qualified = chip == "Apple M5 Max" and memory == 137438953472
    limit = env.get("MTPLX_MEMORY_LIMIT_BYTES")
    if limit is not None:
        require(re.fullmatch(r"[0-9]+", limit) and int(limit) > 0, "MTPLX_MEMORY_LIMIT_BYTES must be positive")
        limit = int(limit)
    elif qualified:
        limit = 111669149696
    return {"profile_id": profile, "api_model_id": MODEL_ID, "runtime_id": RUNTIME_ID,
            "context": context, "mtp_policy": mtp, "mtp_depth": 3 if mtp == "on" else 0,
            "vision": args.vision != "off", "vision_control": "adapter-request-boundary",
            "agent_rewrites": "off", "prompt_path": "native", "scheduler_mode": "serial", "max_active_requests": 1,
            "ssd_session_cache": "off", "fan_mode": "default", "telemetry": False,
            "reasoning": "on", "reasoning_effort": "xhigh", "preserve_thinking": "on",
            "temperature": 1.0, "top_p": 0.95, "top_k": 20, "host": host, "port": int(port),
            "api_key_configured": bool(env.get("METAL_LLM_API_KEY")),
            "hardware_qualified": qualified, "chip": chip, "unified_memory_bytes": memory,
            "memory_limit_bytes": limit, "memory_limit_source": "explicit" if "MTPLX_MEMORY_LIMIT_BYTES" in env else "qualified-104-gib" if qualified else "upstream-default"}


def hardware():
    def read(key):
        result = subprocess.run(["sysctl", "-n", key], text=True, capture_output=True)
        return result.stdout.strip() if result.returncode == 0 else ""
    return read("machdep.cpu.brand_string"), int(read("hw.memsize") or 0)


def launch_arguments(config, snapshot):
    arguments = ["serve", "--model", str(snapshot), "--model-id", MODEL_ID, "--profile", "turbo",
                 "--generation-mode", "mtp" if config["mtp_policy"] == "on" else "ar",
                 "--depth", "3", "--context-window", str(config["context"]),
                 "--host", config["host"], "--port", str(config["port"]), "--fan-mode", "default",
                 "--scheduler-mode", "serial", "--max-active-requests", "1", "--ssd-session-cache", "off",
                 "--agent-rewrites", "off", "--reasoning", "on", "--reasoning-effort", "xhigh",
                 "--preserve-thinking", "on", "--temperature", "1", "--top-p", "0.95", "--top-k", "20", "--no-stats-footer"]
    if config["mtp_policy"] == "off":
        arguments.append("--no-load-mtp")
    if not config["api_key_configured"]:
        arguments.append("--no-auth")
    return arguments


class NativeBoundary:
    """ASGI guard: preserve text bytes; reject vision and settings mutations."""
    def __init__(self, app, vision=True):
        self.app, self.vision = app, vision

    @staticmethod
    def multimodal(value):
        if isinstance(value, dict):
            if value.get("type") in {"image", "image_url", "input_image", "video", "video_url", "input_video", "document"}:
                return True
            if any(k in value for k in ("image_url", "video_url", "images", "videos", "image", "video")):
                return True
            return any(NativeBoundary.multimodal(v) for v in value.values())
        return isinstance(value, list) and any(NativeBoundary.multimodal(v) for v in value)

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] not in {"POST", "PUT", "PATCH", "DELETE"}:
            return await self.app(scope, receive, send)
        path = scope["path"]
        blocked = path in {"/v1/mtplx/settings", "/mtplx/settings", "/v1/mtplx/thermal/fan_mode", "/mtplx/thermal/fan_mode"}
        if blocked:
            return await self.reject(send, "managed runtime settings are immutable")
        if self.vision:
            return await self.app(scope, receive, send)
        # All generation and token-count routes are JSON in pinned 2.11.2.
        if path not in {"/v1/chat/completions", "/v1/messages", "/v1/messages/count_tokens", "/v1/completions", "/v1/embeddings", "/v1/rerank"}:
            return await self.app(scope, receive, send)
        messages, body = [], bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            messages.append(message)
            body.extend(message.get("body", b""))
            if len(body) > 64 * 1024 * 1024:
                return await self.reject(send, "request body too large")
            if not message.get("more_body", False):
                break
        try:
            value = json.loads(body)
        except (ValueError, UnicodeError):
            return await self.reject(send, "expected JSON request")
        content = [value.get(key) for key in ("messages", "prompt", "input")] if isinstance(value, dict) else value
        if self.multimodal(content) or (isinstance(value, dict) and any(key in value for key in ("images", "videos", "image_url", "video_url"))):
            return await self.reject(send, "vision is disabled for this managed server")
        async def replay():
            return messages.pop(0) if messages else await receive()
        return await self.app(scope, replay, send)

    @staticmethod
    async def reject(send, message):
        body = json.dumps({"error": {"message": message, "type": "invalid_request_error"}}).encode()
        await send({"type": "http.response.start", "status": 400, "headers": [(b"content-type", b"application/json")]})
        await send({"type": "http.response.body", "body": body})


def parse_response(response, streaming, model_id):
    require(not streaming or "data: [DONE]" in response, "incomplete MTPLX stream")
    chunks = [json.loads(line[5:].strip()) for line in response.splitlines()
              if line.startswith("data:") and line[5:].strip() not in ("", "[DONE]")] if streaming else [json.loads(response)]
    require(chunks and all(chunk.get("model", model_id) == model_id for chunk in chunks), "API model identity mismatch")
    require(any(chunk.get("model") == model_id for chunk in chunks), "API response missing model identity")
    final = chunks[-1]
    timing, usage = final.get("timings"), final.get("usage")
    require(isinstance(timing, dict) and isinstance(usage, dict), "missing final MTPLX timing or usage")
    for key in ("prompt_n", "predicted_n", "prompt_ms", "predicted_ms", "prompt_per_second", "predicted_per_second", "draft_n", "draft_n_accepted"):
        require(type(timing.get(key)) in (int, float) and math.isfinite(timing[key]) and timing[key] >= 0, "invalid MTPLX timing: " + key)
    for key in ("prompt_n", "predicted_n", "draft_n", "draft_n_accepted"):
        require(type(timing[key]) is int, "invalid MTPLX token count")
    require(timing["prompt_n"] == usage.get("prompt_tokens") and timing["predicted_n"] == usage.get("completion_tokens") and
            timing["draft_n_accepted"] <= timing["draft_n"], "MTPLX timing/usage mismatch")
    content = "".join(choice.get("delta" if streaming else "message", {}).get("content") or ""
                      for chunk in chunks for choice in chunk.get("choices", []))
    return {"timings": timing, "usage": usage, "effective_prompt_tokens": timing["prompt_n"],
            "mtp_selected": timing["draft_n"] > 0, "mtp_route_evidence": "response.timings.draft_n",
            "output_sha256": hashlib.sha256(content.encode()).hexdigest()}


def runtime_paths(root=None):
    root = ROOT if root is None else root
    directory = root / ".lab/runtimes" / RUNTIME_ID
    return directory, directory / "venv", directory / "installation-receipt.json"


def verify_runtime_files(directory, receipt):
    require(bool(receipt["files"]), "empty runtime receipt")
    for name, expected in receipt["files"].items():
        require(not Path(name).is_absolute() and ".." not in Path(name).parts, "unsafe runtime receipt path")
        path = safe_path(directory / name)
        require(path.is_file() and digest(path) == expected, "runtime file checksum mismatch: " + name)


def install_runtime(runtime, root=None):
    root = ROOT if root is None else root
    directory, venv, receipt_path = runtime_paths(root)
    safe_path(directory)
    if receipt_path.exists():
        return verify_runtime(runtime, root)
    require(not venv.exists(), "incomplete runtime environment; move it aside explicitly before retrying setup")
    python = os.environ.get("METAL_LLM_PYTHON") or shutil.which("python3.12")
    require(python, "Python 3.12 is required for the pinned runtime; install Python 3.12 explicitly or set METAL_LLM_PYTHON to its executable. No global packages are installed.")
    version = subprocess.check_output([python, "-I", "-c", "import sys; print('.'.join(map(str,sys.version_info[:2])))"], text=True).strip()
    require(version == "3.12", "METAL_LLM_PYTHON must be Python 3.12")
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run([python, "-I", "-m", "venv", "--copies", str(venv)], check=True)
    executable = venv / "bin/python"
    subprocess.run([str(executable), "-I", "-m", "pip", "--isolated", "install", "--disable-pip-version-check",
                    "--cache-dir", str(directory / "wheel-cache"), "--require-hashes", "--only-binary=:all:",
                    "--no-compile", "-r", str(root / runtime["lock"])], check=True)
    subprocess.run([str(executable), "-I", "-m", "pip", "check"], check=True)
    # Metadata inventory never imports installed package code or MLX.
    inventory = json.loads(subprocess.check_output([str(executable), "-I", "-c",
        "import importlib.metadata as m,json; print(json.dumps({d.metadata['Name'].lower().replace('_','-'):d.version for d in m.distributions()}))"], text=True))
    require(all(inventory.get(p["name"]) == p["version"] for p in runtime["packages"]), "installed dependency versions differ from lock")
    files, symlinks = {}, {}
    for path in sorted(venv.rglob("*")):
        if path.is_symlink():
            require(path.is_dir() and path.resolve().is_relative_to(venv.resolve()), "unsafe runtime symlink")
            symlinks[str(path.relative_to(directory))] = os.readlink(path)
        elif path.is_file():
            files[str(path.relative_to(directory))] = digest(path)
    receipt = {"schema_version": 1, "runtime_id": RUNTIME_ID, "lock_sha256": runtime["lock_sha256"],
               "packages": inventory, "python_version": version, "files": files, "symlinks": symlinks}
    atomic_json(receipt_path, receipt)
    return verify_runtime(runtime, root)


def verify_runtime(runtime, root=None):
    root = ROOT if root is None else root
    directory, venv, receipt_path = runtime_paths(root)
    require(receipt_path.is_file(), "MTPLX runtime is not installed; run setup first")
    fingerprint(receipt_path)
    receipt = json.loads(receipt_path.read_text())
    require(receipt["runtime_id"] == RUNTIME_ID and receipt["lock_sha256"] == runtime["lock_sha256"] and
            receipt["python_version"] == "3.12", "runtime receipt binding mismatch")
    require(all(receipt["packages"].get(p["name"]) == p["version"] for p in runtime["packages"]), "runtime receipt package mismatch")
    verify_runtime_files(directory, receipt)
    symlinks = {str(path.relative_to(directory)): os.readlink(path) for path in venv.rglob("*") if path.is_symlink()}
    require(symlinks == receipt.get("symlinks", {}), "runtime symlink inventory changed")
    # Unexpected importable files are changes too, even if original files remain.
    actual = {str(path.relative_to(directory)) for path in venv.rglob("*")
              if path.is_file() and not path.is_symlink()}
    require(actual == set(receipt["files"]), "runtime file inventory changed")
    return {"id": RUNTIME_ID, "version": runtime["version"], "lock_sha256": runtime["lock_sha256"],
            "manifest_sha256": digest(root / "manifests/runtimes" / (RUNTIME_ID + ".json")),
            "installation_receipt_sha256": digest(receipt_path), "python_sha256": digest(venv / "bin/python"),
            "adapter_sha256": digest(Path(__file__)), "packages": runtime["packages"]}


def snapshot_paths(root=None):
    root = ROOT if root is None else root
    return root / ".lab/artifacts" / MODEL_ID, root / ".lab/verification" / (MODEL_ID + ".json")


def verified_identity(config, model, runtime, mode, root=None):
    root = ROOT if root is None else root
    snapshot, receipt = snapshot_paths(root)
    binding = json_sha(model)
    verification = verify_snapshot(snapshot, model["artifacts"], mode, receipt, binding)
    installed = verify_runtime(runtime, root)
    return {"owner_kind": "serve", "model_id": MODEL_ID, "profile_id": config["profile_id"],
            "runtime_alias": "mtplx", "runtime_id": RUNTIME_ID, "context": config["context"],
            "vision": config["vision"], "mtp_policy": config["mtp_policy"], "mtp_threshold": None,
            "host": config["host"], "port": config["port"], "configuration": config, "runtime": installed,
            "model_revision": model["revision"], "model_manifest_sha256": digest(root / "manifests/models" / (MODEL_ID + ".json")),
            "artifacts": [{"id": a["filename"], "bytes": a["bytes"], "sha256": a["sha256"]} for a in model["artifacts"]],
            "artifact_verification": verification}


def validate_identity(identity):
    require(identity["schema_version"] == 3 and identity["owner_kind"] == "serve" and identity["model_id"] == MODEL_ID and
            identity["runtime_alias"] == "mtplx" and identity["runtime_id"] == RUNTIME_ID and identity["model_revision"] == REVISION,
            "invalid MTPLX managed identity")
    require(type(identity["pid"]) is int and identity["pid"] > 1 and isinstance(identity["process_started_at"], str) and
            re.fullmatch(r"[a-f0-9]{64}", identity["owner_token"]), "invalid managed process owner")
    config = identity["configuration"]
    validate_configuration(config)
    validate_runtime_identity(identity["runtime"])
    for field in ("context", "vision", "mtp_policy", "profile_id", "host", "port", "runtime_id"):
        require(identity[field] == config[field], "managed identity/configuration mismatch")
    require(config["agent_rewrites"] == "off" and config["prompt_path"] == "native" and config["max_active_requests"] == 1 and
            config["scheduler_mode"] == "serial" and config["ssd_session_cache"] == "off" and config["fan_mode"] == "default",
            "managed native-path defaults changed")
    require(identity["runtime"]["id"] == RUNTIME_ID and identity["runtime"]["version"] == "2.11.2", "invalid runtime version")
    for value in (identity["model_manifest_sha256"], *(identity["runtime"][key] for key in
                  ("lock_sha256", "manifest_sha256", "installation_receipt_sha256", "python_sha256", "adapter_sha256"))):
        require(re.fullmatch(r"[a-f0-9]{64}", value), "invalid managed integrity digest")
    require(identity["artifacts"] and all(type(a["bytes"]) is int and a["bytes"] >= 0 and
            re.fullmatch(r"[a-f0-9]{64}", a["sha256"]) for a in identity["artifacts"]), "invalid artifact identity")


def validate_configuration(config):
    args = parse_args(["serve", "--profile", config["profile_id"], "--vision", "on" if config["vision"] else "off"] +
                      (["--mtp", config["mtp_policy"], "--context", str(config["context"])] if config["profile_id"] == "custom" else []))
    env = {"METAL_LLM_HOST": config["host"], "METAL_LLM_PORT": str(config["port"])}
    if config["api_key_configured"]:
        env["METAL_LLM_API_KEY"] = "configured"
    if config["memory_limit_source"] == "explicit":
        env["MTPLX_MEMORY_LIMIT_BYTES"] = str(config["memory_limit_bytes"])
    model, _ = load_manifests()
    expected = resolve_config(args, model, env, config["chip"], config["unified_memory_bytes"])
    require(config == expected, "managed effective configuration mismatch")


def validate_runtime_identity(identity):
    _, runtime = load_manifests()
    require(identity["id"] == runtime["id"] and identity["version"] == runtime["version"] and
            identity["lock_sha256"] == runtime["lock_sha256"] and identity["packages"] == runtime["packages"] and
            identity["manifest_sha256"] == digest(ROOT / "manifests/runtimes" / (RUNTIME_ID + ".json")),
            "runtime provenance differs from pinned manifest")
    for key in ("installation_receipt_sha256", "python_sha256", "adapter_sha256"):
        require(re.fullmatch(r"[a-f0-9]{64}", identity[key]), "invalid runtime integrity digest")


def launch(identity_path, model, runtime):
    identity = json.loads(identity_path.read_text())
    validate_identity(identity)
    config = identity["configuration"]
    current = verified_identity(config, model, runtime, "cached")
    for field in ("model_manifest_sha256", "artifacts", "runtime"):
        require(current[field] == identity[field], "installation changed after lease acquisition")
    local = ROOT / ".lab/mtplx" / MODEL_ID
    safe_path(local)
    local.mkdir(parents=True, exist_ok=True)
    config_path = local / "isolated-config.toml"
    require(not config_path.exists(), "unexpected user config in isolated MTPLX launch directory")
    # Strip inherited tuning/agent options; only the explicitly qualified memory
    # override is admitted. Prevent global HF/user configuration and telemetry.
    for key in list(os.environ):
        if key.startswith("MTPLX_") or key in ("PYTHONPATH", "PYTHONHOME"):
            del os.environ[key]
    os.environ.update({"MTPLX_CONFIG": str(config_path), "MTPLX_AGENT_REWRITES": "off", "MTPLX_FAN_MODE": "default",
                       "HF_HOME": str(local / "hf-cache"), "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                       "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1", "DO_NOT_TRACK": "1", "PYTHONDONTWRITEBYTECODE": "1"})
    if config["memory_limit_bytes"] is not None:
        os.environ["MTPLX_MEMORY_LIMIT_BYTES"] = str(config["memory_limit_bytes"])
    if os.environ.get("METAL_LLM_API_KEY"):
        os.environ["MTPLX_API_KEY"] = os.environ["METAL_LLM_API_KEY"]
    # Runtime-only wrapping: no upstream files or user prompt text are changed.
    from mtplx.server import openai as server
    original = server.create_app
    def create_app(state):
        return NativeBoundary(original(state), vision=config["vision"])
    server.create_app = create_app
    from mtplx import cli
    return cli.main(launch_arguments(config, snapshot_paths()[0]))


def benchmark_cases(args, root=None):
    root = ROOT if root is None else root
    require(args.suite and re.fullmatch(r"[a-z0-9]+([.-][a-z0-9]+)*", args.suite), "bench requires a valid --suite")
    suite_path = root / "benchmarks/suites" / (args.suite + ".json")
    suite = json.loads(suite_path.read_text())
    require(suite.get("schema_version") == 1 and suite.get("id") == args.suite, "invalid benchmark suite")
    mode = args.mode or suite["default_mode"]
    require(mode == "endpoint", "MTPLX does not support local llama-bench suites; use --mode endpoint")
    cases = [case for case in suite["cases"] if case["mode"] == mode and
             (not case.get("optional", False) or os.environ.get("METAL_LLM_INCLUDE_OPTIONAL") == "1")]
    require(cases and all(case["kind"] in ("api", "vision") for case in cases), "unsupported API benchmark cases")
    require(len({c["id"] for c in cases}) == len(cases), "duplicate benchmark case")
    for case in cases:
        require(re.fullmatch(r"[a-z0-9]+([.-][a-z0-9]+)*", case["id"]) and isinstance(case["prompt"], str) and
                type(case["max_tokens"]) is int and case["max_tokens"] > 0 and type(case["seed"]) is int and
                type(case["temperature"]) in (int, float), "invalid benchmark case")
    return suite_path, cases


def api_request(config, path, payload=None):
    host = config["host"]
    if ":" in host and not host.startswith("["):
        host = "[" + host + "]"
    headers = {"Content-Type": "application/json"}
    if os.environ.get("METAL_LLM_API_KEY"):
        headers["Authorization"] = "Bearer " + os.environ["METAL_LLM_API_KEY"]
    request = urllib.request.Request(f"http://{host}:{config['port']}{path}",
                                     data=json.dumps(payload).encode() if payload is not None else None, headers=headers)
    with urllib.request.urlopen(request, timeout=600) as response:
        return response.read().decode()


def bench(args, model, runtime):
    suite_path, cases = benchmark_cases(args)
    if args.dry_run:
        config = resolve_config(args, model, os.environ, *hardware())
        print(json.dumps({"configuration": config, "suite_id": args.suite, "mode": "endpoint", "cases": [c["id"] for c in cases],
                          "provenance": "managed identity, verified snapshot/runtime, native path, raw timings, wall time; live acceptance pending"}, indent=2))
        return
    require(args.identity, "API bench requires a live managed MTPLX server")
    identity_path = Path(args.identity)
    identity = json.loads(identity_path.read_text())
    validate_identity(identity)
    identity_sha = digest(identity_path)
    serving = identity["configuration"]
    if args.profile is None:
        args.profile = serving["profile_id"]
    if args.profile == "custom":
        args.mtp = args.mtp or serving["mtp_policy"]
        args.context = args.context or str(serving["context"])
    args.vision = args.vision or ("on" if serving["vision"] else "off")
    config = resolve_config(args, model, os.environ, *hardware())
    require(config == serving, "requested benchmark settings do not match managed server identity")
    current = verified_identity(config, model, runtime, args.artifact_check)
    for field in ("runtime", "artifacts", "model_manifest_sha256"):
        require(current[field] == identity[field], "managed runtime or artifacts changed")
    git = lambda *a: subprocess.check_output(["git", "-C", str(ROOT), *a], text=True).strip()
    require(not git("status", "--porcelain"), "benchmark provenance requires a clean repository")
    repository = {"revision": git("rev-parse", "HEAD"), "tree_sha": git("rev-parse", "HEAD^{tree}"), "clean": True}
    models = json.loads(api_request(config, "/v1/models"))
    require(any(m.get("id") == MODEL_ID for m in models.get("data", [])), "API /v1/models identity mismatch")
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    runs, fixtures = [], []
    for case in cases:
        require(digest(identity_path) == identity_sha, "managed identity changed during benchmark")
        content = case["prompt"]
        if case["kind"] == "vision":
            require(config["vision"], "vision benchmark requires --vision on")
            relative = Path(case["fixture"])
            require(not relative.is_absolute() and ".." not in relative.parts and relative.parts[:2] == ("benchmarks", "fixtures"), "unsafe fixture path")
            subprocess.run(["git", "-C", str(ROOT), "ls-files", "--error-unmatch", str(relative)], check=True, stdout=subprocess.DEVNULL)
            fixture = safe_path(ROOT / relative)
            require(fixture.suffix.lower() in (".png", ".jpg", ".jpeg"), "unsupported vision fixture type")
            mime = "image/png" if fixture.suffix.lower() == ".png" else "image/jpeg"
            fixtures.append({"path": str(relative), "sha256": digest(fixture)})
            content = [{"type": "text", "text": content}, {"type": "image_url", "image_url": {"url":
                "data:" + mime + ";base64," + base64.b64encode(fixture.read_bytes()).decode()}}]
        streaming = case.get("stream", False)
        payload = {"model": MODEL_ID, "messages": [{"role": "user", "content": content}],
                   "max_tokens": case["max_tokens"], "temperature": case["temperature"], "seed": case["seed"],
                   "top_p": config["top_p"], "top_k": config["top_k"], "stream": streaming}
        if streaming:
            payload["stream_options"] = {"include_usage": True}
        started = time.perf_counter()
        raw = api_request(config, "/v1/chat/completions", payload)
        elapsed = time.perf_counter() - started
        parsed = parse_response(raw, streaming, MODEL_ID)
        require(digest(identity_path) == identity_sha, "managed identity changed during request")
        require(config["mtp_policy"] != "off" or not parsed["mtp_selected"], "AR request unexpectedly used speculative drafts")
        runs.append({"id": case["id"], "timestamp": timestamp, "measurement_kind": "single_run", "experiment": "suite-run",
                     "request_kind": "vision" if case["kind"] == "vision" else "text", "profile_id": config["profile_id"],
                     "runtime_alias": "mtplx", "runtime_id": RUNTIME_ID, "runtime_revision": "2.11.2",
                     "context": config["context"], "vision": config["vision"], "mtp_policy": config["mtp_policy"],
                     "mtp_threshold": None, "prompt_tokens": parsed["usage"]["prompt_tokens"],
                     "generated_tokens": parsed["usage"]["completion_tokens"],
                     "prompt_tokens_per_second": parsed["timings"]["prompt_per_second"],
                     "generation_tokens_per_second": parsed["timings"]["predicted_per_second"],
                     "wall_seconds": elapsed, "stream": streaming, "raw_response": raw,
                     "request_sha256": json_sha(payload), "generation_settings": {k: payload[k] for k in ("max_tokens", "temperature", "top_p", "top_k", "seed")},
                     "reasoning_settings": {k: config[k] for k in ("reasoning", "reasoning_effort", "preserve_thinking")},
                     "prompt_path": "native", "notes": case["notes"], **parsed})
    # Public provenance deliberately excludes PID, local filesystem paths and API secrets.
    provenance = {"repository": repository, "hardware": {"chip": config["chip"], "unified_memory_bytes": config["unified_memory_bytes"]},
                  "system": {"operating_system": platform.system(), "operating_system_version": platform.mac_ver()[0]},
                  "runtime": current["runtime"], "configuration": config, "model_revision": REVISION,
                  "model_manifest_sha256": current["model_manifest_sha256"], "artifacts": current["artifacts"],
                  "artifact_verification": current["artifact_verification"], "suite": {"id": args.suite, "sha256": digest(suite_path), "fixtures": fixtures}}
    result = {"schema_version": 3, "experiment_id": timestamp.replace(":", "").replace("-", "").lower() + "-" + args.suite,
              "date": timestamp[:10], "model_id": MODEL_ID, "suite_id": args.suite, "benchmark_mode": "endpoint",
              "provenance": provenance, "runs": runs}
    validate_result(result)
    results = Path(os.environ.get("METAL_LLM_RESULTS_DIR", str(ROOT / "results/raw")))
    safe_path(results).mkdir(parents=True, exist_ok=True)
    output = results / (result["experiment_id"] + "-" + MODEL_ID + ".json")
    with output.open("x") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print("wrote benchmark result: " + str(output))


def validate_result(result):
    require(result["schema_version"] == 3 and result["model_id"] == MODEL_ID and result["benchmark_mode"] == "endpoint", "invalid MTPLX benchmark identity")
    suite_id = result.get("suite_id", "")
    require(re.fullmatch(r"[a-z0-9]+([.-][a-z0-9]+)*", suite_id), "invalid benchmark suite id")
    suite_path = ROOT / "benchmarks/suites" / (suite_id + ".json")
    require(suite_path.is_file(), "unregistered benchmark suite")
    suite = json.loads(suite_path.read_text())
    cases = {c["id"]: c for c in suite["cases"] if c["mode"] == "endpoint"}
    provenance = result["provenance"]
    validate_configuration(provenance["configuration"])
    validate_runtime_identity(provenance["runtime"])
    require(provenance["suite"]["id"] == suite_id and provenance["suite"]["sha256"] == digest(suite_path), "benchmark suite provenance mismatch")
    require(provenance["model_revision"] == REVISION and provenance["runtime"]["id"] == RUNTIME_ID and
            provenance["runtime"]["version"] == "2.11.2" and provenance["configuration"]["prompt_path"] == "native" and
            provenance["configuration"]["agent_rewrites"] == "off", "invalid MTPLX benchmark provenance")
    require(provenance["repository"]["clean"] is True and
            all(re.fullmatch(r"[a-f0-9]{40}", provenance["repository"][k]) for k in ("revision", "tree_sha")), "invalid repository provenance")
    require(result["runs"], "empty benchmark result")
    require(len({r["id"] for r in result["runs"]}) == len(result["runs"]), "duplicate benchmark run")
    require({c["id"] for c in cases.values() if not c.get("optional", False)} <= {r["id"] for r in result["runs"]}, "missing required benchmark case")
    for run in result["runs"]:
        require(run["id"] in cases, "unregistered benchmark case")
        case = cases[run["id"]]
        require(run["stream"] == case.get("stream", False) and
                all(run["generation_settings"][k] == case[k] for k in ("max_tokens", "temperature", "seed")), "benchmark request settings mismatch")
        parsed = parse_response(run["raw_response"], run["stream"], MODEL_ID)
        require(all(run[key] == value for key, value in parsed.items()), "benchmark response provenance mismatch")
        require(run["prompt_path"] == "native" and math.isfinite(run["wall_seconds"]) and run["wall_seconds"] >= 0 and
                run["context"] == provenance["configuration"]["context"] and
                run["mtp_policy"] == provenance["configuration"]["mtp_policy"], "benchmark settings mismatch")
        require(run["prompt_tokens"] == parsed["usage"]["prompt_tokens"] and run["generated_tokens"] == parsed["usage"]["completion_tokens"] and
                run["generation_tokens_per_second"] == parsed["timings"]["predicted_per_second"] and
                run["prompt_tokens_per_second"] == parsed["timings"]["prompt_per_second"], "benchmark throughput mismatch")


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.command.startswith("validate-"):
        require(args.file, "validation requires --file")
        value = json.loads(Path(args.file).read_text())
        {"validate-model": validate_model, "validate-runtime": validate_runtime,
         "validate-identity": validate_identity, "validate-result": validate_result}[args.command](value)
        return 0
    model, runtime = load_manifests()
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "MTPLX requires macOS arm64")
    if args.command == "setup":
        require(not any((args.profile, args.mtp, args.context, args.vision, args.runtime, args.suite, args.mode, args.identity)), "unsupported setup option")
        snapshot, receipt = snapshot_paths()
        remaining = sum(a["bytes"] - ((snapshot / (a["filename"] + ".part")).stat().st_size if (snapshot / (a["filename"] + ".part")).is_file() else 0)
                        for a in model["artifacts"] if not (snapshot / a["filename"]).exists())
        reserve = os.environ.get("METAL_LLM_BUILD_RESERVE_BYTES", "5368709120")
        require(re.fullmatch(r"[0-9]+", reserve), "invalid METAL_LLM_BUILD_RESERVE_BYTES")
        print(json.dumps({"model_id": MODEL_ID, "runtime_id": RUNTIME_ID, "python_required": "3.12",
                          "snapshot_revision": REVISION, "snapshot_files": len(model["artifacts"]), "remaining_artifact_bytes": remaining,
                          "runtime_reserve_bytes": int(reserve), "import": bool(args.import_from), "artifact_check": args.artifact_check}, indent=2))
        if args.dry_run:
            return 0
        require(shutil.disk_usage(ROOT).free >= remaining + int(reserve), "insufficient disk space for managed snapshot and runtime reserve")
        if not args.yes and sys.stdin.isatty():
            require(input("Install pinned runtime and verified model snapshot? [y/N] ").lower() in ("y", "yes"), "setup cancelled")
        install_runtime(runtime)
        verification = setup_snapshot(snapshot, model["artifacts"], args.artifact_check, receipt, json_sha(model),
                                      Path(args.import_from).absolute() if args.import_from else None)
        print(json.dumps({"artifact_verification": verification, "next": "./bin/metal-llm serve " + MODEL_ID}, indent=2))
        return 0
    require(not args.import_from and not args.yes and not args.file, "option is valid only for setup/validation")
    if args.command == "bench":
        bench(args, model, runtime)
        return 0
    if args.command == "launch":
        require(args.identity, "launch requires managed identity")
        return launch(Path(args.identity), model, runtime)
    require(not args.suite and not args.mode and not args.identity, "unsupported serve option")
    config = resolve_config(args, model, os.environ, *hardware())
    if not config["hardware_qualified"]:
        print("MTPLX hardware is unqualified; using explicit memory override or upstream default. Live acceptance remains pending.", file=sys.stderr)
    if args.dry_run:
        print(json.dumps({"configuration": config, "command": ["mtplx", *launch_arguments(config, Path("artifact:" + MODEL_ID))],
                          "artifact_check": args.artifact_check, "installation_check": "deferred until actual launch"}, indent=2))
    else:
        print(json.dumps(verified_identity(config, model, runtime, args.artifact_check)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print("metal-llm: " + str(error), file=sys.stderr)
        sys.exit(1)
