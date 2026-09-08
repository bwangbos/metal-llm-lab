"""Offline adapter contracts; no imports of MTPLX/MLX or model inference."""
import asyncio
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mtplx_adapter", ROOT / "lib/mtplx_adapter.py")
adapter = importlib.util.module_from_spec(SPEC)
if SPEC.loader and Path(SPEC.origin).exists():
    SPEC.loader.exec_module(adapter)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def artifact(self, data=b"fixture data", name="config.json"):
        return {"filename": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                "url": "https://huggingface.co/example/resolve/" + "a" * 40 + "/" + name}

    def test_manifest_rejects_path_escape_duplicate_and_revision_drift(self):
        model, runtime = adapter.load_manifests(ROOT)
        for change in (lambda m: m["artifacts"][0].update(filename="../escape"),
                       lambda m: m["artifacts"].append(m["artifacts"][0]),
                       lambda m: m["artifacts"].__setitem__(slice(None), [a for a in m["artifacts"] if a["filename"] != "merges.txt"]),
                       lambda m: m.update(revision="main")):
            bad = copy.deepcopy(model)
            change(bad)
            with self.assertRaises(ValueError):
                adapter.validate_model(bad)
        adapter.validate_runtime(runtime, ROOT)

    def test_configuration_qualifies_memory_and_preserves_explicit_override(self):
        args = adapter.parse_args(["serve"])
        model, _ = adapter.load_manifests(ROOT)
        config = adapter.resolve_config(args, model, {}, "Apple M5 Max", 137438953472)
        self.assertEqual((config["context"], config["mtp_depth"], config["vision"]), (262144, 3, True))
        self.assertEqual(config["memory_limit_bytes"], 111669149696)
        self.assertEqual(config["agent_rewrites"], "off")
        self.assertEqual(config["scheduler_mode"], "serial")
        other = adapter.resolve_config(args, model, {}, "Apple M4 Max", 137438953472)
        self.assertIsNone(other["memory_limit_bytes"])
        self.assertFalse(other["hardware_qualified"])
        override = adapter.resolve_config(args, model, {"MTPLX_MEMORY_LIMIT_BYTES": "123"}, "Apple M4", 16)
        self.assertEqual(override["memory_limit_bytes"], 123)

    def test_invalid_options_fail_before_artifacts_or_launch(self):
        model, _ = adapter.load_manifests(ROOT)
        for argv in (["--runtime", "tuned"], ["--mtp", "on"],
                     ["--profile", "custom", "--mtp", "dynamic", "--context", "8192"],
                     ["--profile", "custom", "--mtp", "on"],
                     ["--profile", "custom", "--mtp", "off", "--context", "262145"],
                     ["--profile", "auto"]):
            with self.subTest(argv=argv), self.assertRaises((ValueError, SystemExit)):
                adapter.resolve_config(adapter.parse_args(["serve"] + argv), model, {}, "", 0)
        with self.assertRaises(ValueError):
            adapter.resolve_config(adapter.parse_args(["serve"]), model, {"METAL_LLM_PARALLEL": "2"}, "", 0)

    def test_cached_verification_invalidates_same_length_content_and_full_rehashes(self):
        artifact = self.artifact()
        snapshot = self.root / "snapshot"
        snapshot.mkdir()
        target = snapshot / artifact["filename"]
        target.write_bytes(b"fixture data")
        first = adapter.verify_snapshot(snapshot, [artifact], "full", self.root / "receipt.json", "pin")
        self.assertEqual(first["full_hashes"], 1)
        second = adapter.verify_snapshot(snapshot, [artifact], "cached", self.root / "receipt.json", "pin")
        self.assertEqual(second["cache_hits"], 1)
        target.write_bytes(b"corrupt data")
        with self.assertRaisesRegex(ValueError, "checksum"):
            adapter.verify_snapshot(snapshot, [artifact], "cached", self.root / "receipt.json", "pin")

    def test_import_copies_verified_source_without_mutation(self):
        source = self.root / "source"
        source.mkdir()
        (source / "config.json").write_bytes(b"fixture data")
        original = (source / "config.json").stat()
        destination = self.root / "managed"
        adapter.install_snapshot(destination, [self.artifact()], source=source)
        self.assertEqual((destination / "config.json").read_bytes(), b"fixture data")
        self.assertNotEqual(original.st_ino, (destination / "config.json").stat().st_ino)
        self.assertEqual(original.st_mtime_ns, (source / "config.json").stat().st_mtime_ns)
        (source / "config.json").write_bytes(b"corrupt data")
        with self.assertRaisesRegex(ValueError, "checksum"):
            adapter.install_snapshot(self.root / "other", [self.artifact()], source=source)

    def test_completed_partial_promotes_and_bad_partial_never_publishes(self):
        target = self.root / "managed"
        target.mkdir()
        (target / "config.json.part").write_bytes(b"fixture data")
        adapter.install_snapshot(target, [self.artifact()])
        self.assertEqual((target / "config.json").read_bytes(), b"fixture data")
        (target / "bad.part").write_bytes(b"corrupt data")
        with self.assertRaisesRegex(ValueError, "checksum"):
            adapter.install_snapshot(target, [self.artifact(name="bad")])
        self.assertFalse((target / "bad").exists())

    def test_symlinked_destination_and_source_escape_rejected(self):
        external = self.root / "external"
        external.mkdir()
        unsafe = self.root / "unsafe"
        unsafe.symlink_to(external, target_is_directory=True)
        with self.assertRaises(ValueError):
            adapter.install_snapshot(unsafe, [self.artifact()])
        (external / "config.json").symlink_to("/etc/passwd")
        with self.assertRaises(ValueError):
            adapter.install_snapshot(self.root / "managed", [self.artifact()], source=external)

    def test_dry_run_no_install_required_and_key_never_printed(self):
        result = subprocess.run([str(ROOT / "bin/metal-llm"), "serve", "qwen3.8-flash-next-mtplx", "--dry-run"],
                                env={**os.environ, "METAL_LLM_API_KEY": "private-test-key"}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"api_model_id": "qwen3.8-flash-next-mtplx"', result.stdout)
        self.assertNotIn("private-test-key", result.stdout + result.stderr)
        self.assertIn('"agent_rewrites": "off"', result.stdout)

    def test_api_response_provenance_uses_actual_drafts_not_configured_policy(self):
        response = {"model": "qwen3.8-flash-next-mtplx", "choices": [{"message": {"content": "ok"}}],
                    "usage": {"prompt_tokens": 8, "completion_tokens": 2},
                    "timings": {"prompt_n": 8, "predicted_n": 2, "prompt_ms": 20, "predicted_ms": 100,
                                "prompt_per_second": 400, "predicted_per_second": 20,
                                "draft_n": 0, "draft_n_accepted": 0}}
        parsed = adapter.parse_response(json.dumps(response), False, response["model"])
        self.assertFalse(parsed["mtp_selected"])
        self.assertEqual(parsed["effective_prompt_tokens"], 8)
        self.assertEqual(parsed["timings"]["predicted_per_second"], 20)
        response["model"] = "wrong"
        with self.assertRaises(ValueError):
            adapter.parse_response(json.dumps(response), False, "qwen3.8-flash-next-mtplx")

    def test_vision_boundary_rejects_multimodal_without_calling_app(self):
        async def exercise(payload):
            called, sent = [], []
            async def app(scope, receive, send):
                called.append(json.loads((await receive())["body"]))
            async def receive():
                return {"type": "http.request", "body": json.dumps(payload).encode()}
            async def send(message):
                sent.append(message)
            await adapter.NativeBoundary(app, vision=False)({"type": "http", "method": "POST", "path": "/v1/messages"}, receive, send)
            return called, sent
        for content in ({"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}},
                        {"type": "image", "source": {"type": "base64", "data": "AA"}},
                        {"type": "video_url", "video_url": "example"}):
            called, sent = asyncio.run(exercise({"messages": [{"role": "user", "content": [content]}]}))
            self.assertEqual(called, [])
            self.assertEqual(sent[0]["status"], 400)
        called, sent = asyncio.run(exercise({"messages": [{"role": "user", "content": "hello"}]}))
        self.assertEqual(len(called), 1)
        self.assertEqual(sent, [])

    def test_local_bench_explicitly_unsupported(self):
        result = subprocess.run([str(ROOT / "bin/metal-llm"), "bench", "qwen3.8-flash-next-mtplx",
                                 "--suite", "qwen3.8-smoke", "--mode", "local", "--dry-run"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("llama-bench", result.stderr)

    def test_runtime_receipt_rejects_dependency_and_launcher_mutation(self):
        runtime_dir = self.root / "runtime"
        runtime_dir.mkdir()
        package = runtime_dir / "package.py"
        package.write_text("original")
        receipt = {"files": {"package.py": hashlib.sha256(b"original").hexdigest()}}
        adapter.verify_runtime_files(runtime_dir, receipt)
        package.write_text("modified")
        with self.assertRaisesRegex(ValueError, "runtime.*checksum"):
            adapter.verify_runtime_files(runtime_dir, receipt)

    def test_installer_pins_hashes_and_cache_then_records_verifiable_installation(self):
        model, runtime = adapter.load_manifests(ROOT)
        manifest = self.root / "manifests/runtimes/mtplx-2.11.2.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps(runtime))
        commands = []
        def execute(command, **kwargs):
            commands.append(command)
            if "venv" in command:
                venv = Path(command[-1])
                (venv / "bin").mkdir(parents=True)
                (venv / "bin/python").write_bytes(b"fixture interpreter")
            return subprocess.CompletedProcess(command, 0)
        inventory = {p["name"]: p["version"] for p in runtime["packages"]}
        with patch.dict(os.environ, {"METAL_LLM_PYTHON": "/fixture/python3.12"}), \
             patch.object(adapter.subprocess, "run", execute), \
             patch.object(adapter.subprocess, "check_output", side_effect=["3.12\n", json.dumps(inventory)]):
            installed = adapter.install_runtime(runtime, self.root)
        self.assertEqual(installed["version"], "2.11.2")
        self.assertEqual(installed["python_sha256"], hashlib.sha256(b"fixture interpreter").hexdigest())
        install = next(command for command in commands if "install" in command)
        self.assertIn("--require-hashes", install)
        self.assertIn("--only-binary=:all:", install)
        self.assertIn("--cache-dir", install)
        self.assertEqual(install[install.index("--cache-dir") + 1], str(self.root / ".lab/runtimes/mtplx-2.11.2/wheel-cache"))
        adapter.verify_runtime(runtime, self.root)
        bytecode = self.root / ".lab/runtimes/mtplx-2.11.2/venv/lib/__pycache__/unexpected.pyc"
        bytecode.parent.mkdir(parents=True)
        bytecode.write_bytes(b"unexpected importable bytecode")
        with self.assertRaisesRegex(ValueError, "inventory"):
            adapter.verify_runtime(runtime, self.root)
        bytecode.unlink()
        (bytecode.parent / "injected.py").symlink_to(self.root / ".lab/runtimes/mtplx-2.11.2/venv/bin/python")
        with self.assertRaisesRegex(ValueError, "symlink"):
            adapter.verify_runtime(runtime, self.root)

    def test_stream_final_usage_timing_and_empty_content_supported(self):
        chunk = {"model": "qwen3.8-flash-next-mtplx", "choices": [{"delta": {"content": ""}}],
                 "usage": {"prompt_tokens": 7, "completion_tokens": 3},
                 "timings": {"prompt_n": 7, "predicted_n": 3, "prompt_ms": 20, "predicted_ms": 10,
                             "prompt_per_second": 350, "predicted_per_second": 300,
                             "draft_n": 2, "draft_n_accepted": 1}}
        parsed = adapter.parse_response("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n", True, chunk["model"])
        self.assertTrue(parsed["mtp_selected"])
        self.assertEqual(parsed["output_sha256"], hashlib.sha256(b"").hexdigest())

    def test_resume_requests_remaining_range_and_preserves_partial_on_bad_server(self):
        import io
        directory = self.root / "resume"
        directory.mkdir()
        partial = directory / "config.json.part"
        partial.write_bytes(b"fixture ")
        class Response(io.BytesIO):
            status = 206
            headers = {"Content-Range": "bytes 8-11/12"}
        requests = []
        def open_request(request, timeout):
            requests.append(request)
            return Response(b"data")
        with patch.object(adapter.urllib.request, "urlopen", open_request):
            adapter.install_snapshot(directory, [self.artifact()])
        self.assertEqual((directory / "config.json").read_bytes(), b"fixture data")
        self.assertEqual(requests[0].get_header("Range"), "bytes=8-")
        other = self.root / "bad-resume"
        other.mkdir()
        (other / "config.json.part").write_bytes(b"fixture ")
        Response.status = 200
        with patch.object(adapter.urllib.request, "urlopen", open_request), self.assertRaisesRegex(ValueError, "resume"):
            adapter.install_snapshot(other, [self.artifact()])
        self.assertEqual((other / "config.json.part").read_bytes(), b"fixture ")

    def test_snapshot_preserves_empty_metadata(self):
        directory = self.root / "empty"
        adapter.install_snapshot(directory, [self.artifact(b"", ".metadata_never_index")])
        self.assertEqual((directory / ".metadata_never_index").read_bytes(), b"")

    def test_reject_unregistered_benchmark_result_before_accepting_claims(self):
        with self.assertRaises(ValueError):
            adapter.validate_result({"schema_version": 3, "model_id": adapter.MODEL_ID, "benchmark_mode": "endpoint",
                                     "suite_id": "unknown", "provenance": {}, "runs": []})

    def test_native_boundary_blocks_runtime_settings_changes_with_vision_on(self):
        async def exercise():
            called, sent = [], []
            async def app(scope, receive, send):
                called.append(True)
            async def receive():
                return {"type": "http.request", "body": b"{}"}
            async def send(message):
                sent.append(message)
            await adapter.NativeBoundary(app, vision=True)({"type": "http", "method": "POST", "path": "/v1/mtplx/settings"}, receive, send)
            return called, sent
        called, sent = asyncio.run(exercise())
        self.assertFalse(called)
        self.assertEqual(sent[0]["status"], 400)

    def test_vision_off_preserves_text_tool_schema_with_image_property(self):
        async def exercise():
            captured = []
            payload = {"messages": [{"role": "user", "content": "hello"}],
                       "tools": [{"type": "function", "function": {"name": "save", "parameters": {"properties": {"image": {"type": "string"}}}}}]}
            async def app(scope, receive, send):
                captured.append(json.loads((await receive())["body"]))
            async def receive():
                return {"type": "http.request", "body": json.dumps(payload).encode()}
            async def send(message):
                pass
            await adapter.NativeBoundary(app, vision=False)({"type": "http", "method": "POST", "path": "/v1/chat/completions"}, receive, send)
            return captured, payload
        captured, payload = asyncio.run(exercise())
        self.assertEqual(captured, [payload])

    def test_cached_setup_does_not_rehash_verified_existing_weights(self):
        target = self.root / "managed"
        target.mkdir()
        (target / "config.json").write_bytes(b"fixture data")
        receipt = self.root / "receipt.json"
        adapter.verify_snapshot(target, [self.artifact()], "full", receipt, "pin")
        result = adapter.setup_snapshot(target, [self.artifact()], "cached", receipt, "pin")
        self.assertEqual(result["cache_hits"], 1)
        self.assertEqual(result["full_hashes"], 0)

    def test_offline_endpoint_bench_roundtrip_is_report_validated_and_detects_forgery(self):
        """Real tiny install/lease/result, with only external HTTP substituted."""
        import io
        model, runtime = adapter.load_manifests(ROOT)
        for artifact in model["artifacts"]:
            data = ("test " + artifact["filename"]).encode()
            artifact.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            path = self.root / ".lab/artifacts" / adapter.MODEL_ID / artifact["filename"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        for relative, value in (("manifests/models/" + adapter.MODEL_ID + ".json", model),
                                ("manifests/runtimes/" + adapter.RUNTIME_ID + ".json", runtime)):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))
        for relative in (runtime["lock"], "benchmarks/suites/qwen3.8-smoke.json"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / relative).read_bytes())
        installed = self.root / ".lab/runtimes" / adapter.RUNTIME_ID
        (installed / "venv/bin").mkdir(parents=True)
        (installed / "venv/bin/python").write_bytes(b"test interpreter")
        receipt = {"schema_version": 1, "runtime_id": adapter.RUNTIME_ID, "lock_sha256": runtime["lock_sha256"],
                   "python_version": "3.12", "packages": {p["name"]: p["version"] for p in runtime["packages"]},
                   "files": {"venv/bin/python": hashlib.sha256(b"test interpreter").hexdigest()}}
        adapter.atomic_json(installed / "installation-receipt.json", receipt)
        (self.root / ".gitignore").write_text(".lab/\n")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "fixture"], check=True)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("METAL_LLM_", "MTPLX_"))}
        requests = []
        response = {"model": adapter.MODEL_ID, "choices": [{"message": {"content": "METAL-LLM-SMOKE"}}],
                    "usage": {"prompt_tokens": 8, "completion_tokens": 2},
                    "timings": {"prompt_n": 8, "predicted_n": 2, "prompt_ms": 20, "predicted_ms": 100,
                                "prompt_per_second": 400, "predicted_per_second": 20, "draft_n": 0, "draft_n_accepted": 0}}
        def respond(request, timeout):
            requests.append(request)
            payload = {"data": [{"id": adapter.MODEL_ID}]} if request.full_url.endswith("/v1/models") else response
            return io.BytesIO(json.dumps(payload).encode())
        with patch.object(adapter, "ROOT", self.root), patch.dict(os.environ, env, clear=True), patch.object(adapter.urllib.request, "urlopen", respond):
            config = adapter.resolve_config(adapter.parse_args(["serve"]), model, os.environ, *adapter.hardware())
            identity = adapter.verified_identity(config, model, runtime, "full")
            identity.update(schema_version=3, owner_token="a" * 64, pid=os.getpid(), process_started_at="fixture start")
            identity_path = self.root / ".lab/identity.json"
            adapter.atomic_json(identity_path, identity)
            adapter.validate_identity(identity)
            bad_identity = copy.deepcopy(identity)
            bad_identity["configuration"]["telemetry"] = True
            with self.subTest("identity telemetry"), self.assertRaises(ValueError):
                adapter.validate_identity(bad_identity)
            args = adapter.parse_args(["bench", "--suite", "qwen3.8-smoke", "--mode", "endpoint", "--identity", str(identity_path)])
            adapter.bench(args, model, runtime)
            result = json.loads(next((self.root / "results/raw").glob("*.json")).read_text())
            adapter.validate_result(result)
            (self.root / "lib").mkdir()
            (self.root / "lib/mtplx_adapter.py").write_bytes((ROOT / "lib/mtplx_adapter.py").read_bytes())
            report = subprocess.run(["zsh", "-c", 'METAL_LLM_ROOT=$1; source "$2/lib/common.zsh"; source "$2/lib/report.zsh"; metal_llm_validate_result "$3" && metal_llm_generate_generic_summary "$3"',
                                     "fixture", str(self.root), str(ROOT), str(next((self.root / "results/raw").glob("*.json")))], capture_output=True, text=True)
            self.assertEqual(report.returncode, 0, report.stderr)
            self.assertIn("deterministic-api-smoke", report.stdout)
            bad_result = copy.deepcopy(result)
            bad_result["provenance"]["runtime"]["lock_sha256"] = "0" * 64
            with self.assertRaises(ValueError):
                adapter.validate_result(bad_result)
            self.assertEqual(result["runs"][0]["generation_tokens_per_second"], 20)
            self.assertEqual(json.loads(requests[1].data)["model"], adapter.MODEL_ID)
            self.assertEqual(result["provenance"]["configuration"]["agent_rewrites"], "off")
            result["runs"][0]["generation_tokens_per_second"] = 999
            with self.assertRaisesRegex(ValueError, "throughput"):
                adapter.validate_result(result)


if __name__ == "__main__":
    unittest.main()
