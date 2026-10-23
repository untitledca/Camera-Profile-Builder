#!/usr/bin/env python3
"""Exercise the native plugin against loopback camera and Stream Deck servers.

Default execution never connects to camera hardware or changes Stream Deck data.
The binary must support CAMERA_BUILDER_CONFIG_DIR, and each plugin process gets
its own temporary configuration directory. Only --hardware-address opts into the
separate, deliberately narrow white-balance step/restore diagnostic.

Python 3.10+; standard library only.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_EXECUTABLE = ROOT / "build/Camera Profile Builder.app/Contents/MacOS/CameraProfileBuilder"
EXECUTABLE = DEFAULT_EXECUTABLE
HARDWARE_ADDRESS: str | None = None
HARDWARE_EVIDENCE = {}
MOCK_METRICS = {}
FIXTURE = ROOT / "tests/fixtures/camera.json"
ENUM_SOURCE = ROOT / "tests/fixtures/camera-enums.js"
PLUGIN_UUID = "com.atomfilmlab.camera-control"
WAIT_SECONDS = 12.0


def eventually(predicate, description, timeout=WAIT_SECONDS):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.025)
    raise AssertionError(f"Timed out waiting for {description}")


def camera_read(address):
    # All callers either supply a harness-owned 127.0.0.1 endpoint, or the
    # explicit --hardware-address argument. Never use a configured user camera.
    request = urllib.request.Request(f"http://{address}/all.cgi", headers={"Cache-Control": "no-cache"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=4) as response:
        return json.load(response)


class MockReadGate:
    """Hold loopback snapshot responses while allowing concurrent POSTs.

    A cancelled client request may still leave its handler waiting here. Every
    waiting handler is released by close(), and no camera state lock is held.
    """

    def __init__(self):
        self.entered = threading.Event()
        self.released = threading.Event()
        self.lock = threading.Lock()
        self.arrivals = 0

    def wait(self):
        with self.lock:
            self.arrivals += 1
        self.entered.set()
        # A test failure must not leave an indefinitely blocked server thread.
        self.released.wait(timeout=15)

    def close(self):
        self.released.set()


class MockCamera:
    def __init__(self, *, different_ei_order=False, get_delay_seconds=0.0):
        self.document = json.loads(FIXTURE.read_text())
        self.enum_source = ENUM_SOURCE.read_text()
        self.lock = threading.RLock()
        self.online = True
        self.reject_writes = False
        self.accept_without_apply = False
        self.writes = []
        self.calls = []
        self.requests = []
        self.request_log = []
        self.get_delay_seconds = get_delay_seconds
        self.read_gate = None
        if different_ei_order:
            # Model a second firmware that assigns EI 1000 index 7 and EI 800
            # index 8. Translation strings remain unchanged. This makes a raw
            # enum-index broadcast fail even when ordinary WB ganging works.
            before = 'ExposureIndex:"EI_160 EI_200 EI_250 EI_320 EI_400 EI_500 EI_640 EI_800 EI_1000 EI_1280 EI_1600 EI_2000 EI_2560 EI_3200".split(" ")'
            after = before.replace("EI_800 EI_1000", "EI_1000 EI_800")
            if before not in self.enum_source:
                raise AssertionError("Recorded camera enum fixture changed; review EI mock mapping")
            self.enum_source = self.enum_source.replace(before, after, 1)

        camera = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def reply(self, value, status=200, *, text=False):
                data = value.encode() if text else json.dumps(value).encode()
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/javascript" if text else "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    # Command priority is allowed to cancel an in-flight read.
                    pass
                self.close_connection = True

            def do_GET(self):
                with camera.lock:
                    camera.record_request("GET", self.path)
                    delay = camera.get_delay_seconds if self.path == "/all.cgi" else 0
                    gate = camera.read_gate if self.path == "/all.cgi" else None
                # Deliberately outside camera.lock: a slow snapshot must not
                # prevent the mock from accepting a command on another socket.
                if gate is not None:
                    gate.wait()
                if delay:
                    time.sleep(delay)
                with camera.lock:
                    if not camera.online:
                        self.reply({"ERROR": "Camera disconnected"}, 503)
                    elif self.path == "/all.cgi":
                        self.reply(camera.document)
                    elif self.path == "/js/all-dg.min.js":
                        self.reply(camera.enum_source, text=True)
                    else:
                        self.reply({"ERROR": "Unexpected mock endpoint"}, 404)

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length))
                with camera.lock:
                    camera.record_request("POST", self.path, body=body)
                    if not camera.online:
                        self.reply({"ERROR": "Camera disconnected"}, 503)
                    elif self.path == "/set.cgi":
                        camera.writes.append(copy.deepcopy(body))
                        if camera.reject_writes:
                            self.reply({"result": 0, "error": "Mock camera refused the setting"})
                            return
                        for key, value in body.items():
                            metadata = camera.document["variables"].get(key)
                            if metadata is None or metadata.get("readonly"):
                                self.reply({"result": 0, "error": "Unavailable or read only"})
                                return
                            if not isinstance(value, (int, float)):
                                self.reply({"result": 0, "error": "Invalid numeric value"})
                                return
                            if not metadata["min"] <= value <= metadata["max"]:
                                self.reply({"result": 0, "error": "Out of camera range"})
                                return
                        if not camera.accept_without_apply:
                            for key, value in body.items():
                                camera.document["variables"][key]["value"] = value
                            camera.document["id"] += 1
                        self.reply({"result": 1})
                    elif self.path == "/call.cgi":
                        camera.calls.append(copy.deepcopy(body))
                        if body.get("command") not in camera.document["commands"]:
                            self.reply({"result": -1, "error": "Unknown command ID"})
                        else:
                            name = camera.document["commands"][body["command"]]
                            if name == "PlayBackGo":
                                camera.change("PlaybackSpeedEnum", 11)
                            elif name == "PlayBackStop":
                                camera.change("PlaybackSpeedEnum", 10)
                            self.reply({"result": 0})
                    else:
                        self.reply({"ERROR": "Unexpected mock endpoint"}, 404)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.address = f"127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def value(self, key):
        with self.lock:
            return self.document["variables"][key]["value"]

    def record_request(self, method, path, *, body=None):
        # Caller holds the reentrant state lock. Timestamp request arrival, not
        # completion, so a blocked GET cannot conceal a promptly received POST.
        self.requests.append((method, path))
        self.request_log.append({"method": method, "path": path, "at": time.monotonic(),
                                 "body": copy.deepcopy(body)})

    def mark_requests(self):
        with self.lock:
            return len(self.request_log)

    def requests_since(self, marker=0):
        with self.lock:
            return copy.deepcopy(self.request_log[marker:])

    def change(self, key, value):
        with self.lock:
            self.document["variables"][key]["value"] = value
            self.document["id"] += 1

    def close(self):
        if self.read_gate is not None:
            self.read_gate.close()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class MockStreamDeck:
    """Small RFC 6455 server: text frames, masking, fragmentation, ping, close."""

    def __init__(self):
        self.messages = []
        self.condition = threading.Condition()
        self.send_lock = threading.Lock()
        self.connection = None
        self.error = None
        deck = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                try:
                    connection = self.request
                    header = bytearray()
                    while not header.endswith(b"\r\n\r\n"):
                        chunk = connection.recv(1)
                        if not chunk:
                            return
                        header.extend(chunk)
                        if len(header) > 65536:
                            raise ValueError("WebSocket upgrade header too large")
                    lines = header.decode("ascii").split("\r\n")
                    headers = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
                    key = next(value.strip() for name, value in headers.items() if name.lower() == "sec-websocket-key")
                    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
                    connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                    deck.connection = connection
                    fragmented = bytearray()
                    while True:
                        first, second = self.read_exact(2)
                        opcode, final = first & 0x0F, bool(first & 0x80)
                        length = second & 0x7F
                        if length == 126:
                            length = struct.unpack("!H", self.read_exact(2))[0]
                        elif length == 127:
                            length = struct.unpack("!Q", self.read_exact(8))[0]
                        if length > 8 * 1024 * 1024:
                            raise ValueError("WebSocket frame too large")
                        mask = self.read_exact(4) if second & 0x80 else None
                        data = self.read_exact(length)
                        if mask:
                            data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
                        if opcode == 8:
                            deck.frame(data, opcode=8)
                            return
                        if opcode == 9:
                            deck.frame(data, opcode=10)
                            continue
                        if opcode == 10:
                            continue
                        if opcode not in (0, 1, 2):
                            raise ValueError(f"Unexpected opcode {opcode}")
                        fragmented.extend(data)
                        if final:
                            message = json.loads(fragmented.decode())
                            fragmented.clear()
                            with deck.condition:
                                deck.messages.append(message)
                                deck.condition.notify_all()
                except (EOFError, ConnectionError, OSError):
                    pass
                except Exception as error:
                    with deck.condition:
                        deck.error = error
                        deck.condition.notify_all()

            def read_exact(self, count):
                value = bytearray()
                while len(value) < count:
                    chunk = self.request.recv(count - len(value))
                    if not chunk:
                        raise EOFError()
                    value.extend(chunk)
                return bytes(value)

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def frame(self, data, opcode=1):
        if len(data) < 126:
            header = bytes([0x80 | opcode, len(data)])
        elif len(data) < 65536:
            header = bytes([0x80 | opcode, 126]) + struct.pack("!H", len(data))
        else:
            header = bytes([0x80 | opcode, 127]) + struct.pack("!Q", len(data))
        with self.send_lock:
            self.connection.sendall(header + data)

    def send(self, message):
        if self.connection is None:
            raise AssertionError("Plugin has not connected")
        self.frame(json.dumps(message).encode())

    def mark(self):
        with self.condition:
            return len(self.messages)

    def since(self, index=0):
        with self.condition:
            return copy.deepcopy(self.messages[index:])

    def wait(self, predicate, description, *, after=0, timeout=WAIT_SECONDS):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                if self.error:
                    raise AssertionError(f"Mock Stream Deck failed: {self.error}")
                for message in self.messages[after:]:
                    if predicate(message):
                        return copy.deepcopy(message)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    recent = self.messages[max(after, len(self.messages) - 8):]
                    raise AssertionError(f"Timed out waiting for {description}; recent events: {recent}")
                self.condition.wait(remaining)

    def feedback(self, context, value, *, after=0, timeout=WAIT_SECONDS):
        return self.wait(lambda message: message.get("event") == "setFeedback" and message.get("context") == context and message.get("payload", {}).get("value") == value,
                         f"{context} feedback {value!r}", after=after, timeout=timeout)

    def close(self):
        if self.connection is not None:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class PluginHarness:
    def __init__(self, cameras, *, feedback_mode=None):
        if b"CAMERA_BUILDER_CONFIG_DIR" not in EXECUTABLE.read_bytes():
            raise AssertionError("Refusing to launch binary without test configuration override support")
        self.temporary = tempfile.TemporaryDirectory(prefix="camera-plugin-integration-")
        self.directory = Path(self.temporary.name)
        self.config_directory = self.directory / "config"
        self.config_directory.mkdir()
        # Match deployment inside .sdPlugin rather than launch from the GUI app
        # bundle. macOS otherwise groups the prohibited plugin process with the
        # open builder app and can disturb its visibility/activation policy.
        self.plugin_executable = self.directory / "CameraControlPlugin"
        shutil.copy2(EXECUTABLE, self.plugin_executable)
        self.config = {
            "cameras": [{"id": identifier, "name": name, "model": "ALEXA Mini LF", "address": address}
                        for identifier, name, address in cameras],
            "selectedCameraID": cameras[0][0], "gangIDs": [item[0] for item in cameras],
            "gangEnabled": False, "gangMode": "absolute",
        }
        if feedback_mode is not None:
            self.config["feedbackMode"] = feedback_mode
        (self.config_directory / "config.json").write_text(json.dumps(self.config))
        self.deck = MockStreamDeck()
        self.output = open(self.directory / "process.log", "w+")
        environment = os.environ.copy()
        environment["CAMERA_BUILDER_CONFIG_DIR"] = str(self.config_directory)
        self.process = subprocess.Popen([str(self.plugin_executable), "-port", str(self.deck.port),
                                         "-pluginUUID", PLUGIN_UUID, "-registerEvent", "registerPlugin", "-info", "{}"],
                                        env=environment, stdout=self.output, stderr=subprocess.STDOUT)
        try:
            self.deck.wait(lambda message: message == {"event": "registerPlugin", "uuid": PLUGIN_UUID}, "native plugin registration")
            eventually(lambda: (self.config_directory / "plugin.log").exists(), "isolated plugin log")
        except Exception as error:
            self.output.flush()
            diagnostic = (self.directory / "process.log").read_text()
            self.close()
            raise AssertionError(f"Plugin startup failed: {error}\n{diagnostic}") from error

    def appear(self, context, parameter="wb", camera_id="A", *, command=None, action_uuid=None):
        settings = {"cameraID": camera_id, "parameter": parameter}
        if command:
            settings["command"] = command
        self.deck.send({"event": "willAppear", "action": action_uuid or PLUGIN_UUID + (".button" if command else ".dial"),
                        "context": context, "device": "mock-stream-deck-plus",
                        "payload": {"controller": "Keypad" if command else "Encoder", "coordinates": {"column": 0, "row": 0},
                                    "settings": settings, "isInMultiAction": False}})

    def rotate(self, context, ticks=1, *, pressed=False):
        self.deck.send({"event": "dialRotate", "context": context,
                        "payload": {"controller": "Encoder", "ticks": ticks, "pressed": pressed}})

    def release(self, context):
        self.deck.send({"event": "dialUp", "context": context, "payload": {"controller": "Encoder"}})

    def assert_alert(self, context, *, after=0):
        self.deck.wait(lambda message: message.get("event") == "showAlert" and message.get("context") == context,
                       f"{context} failed-action alert", after=after)
        self.deck.wait(lambda message: message.get("event") == "setFeedback" and message.get("context") == context
                       and re.search(r"FAIL|ERROR|PARTIAL", message.get("payload", {}).get("value", "")),
                       f"{context} explicit failure feedback", after=after)

    def close(self):
        process = getattr(self, "process", None)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
        deck = getattr(self, "deck", None)
        if deck:
            deck.close()
        output = getattr(self, "output", None)
        if output:
            output.close()
        temporary = getattr(self, "temporary", None)
        if temporary:
            temporary.cleanup()


class MockPluginIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.a = MockCamera()
        self.addCleanup(self.a.close)
        self.b = MockCamera(different_ei_order=True)
        self.addCleanup(self.b.close)
        self.plugin = PluginHarness([("A", "Camera A", self.a.address), ("B", "Camera B", self.b.address)])
        self.addCleanup(self.plugin.close)
        self.deck = self.plugin.deck

    def test_initial_feedback_rotation_and_external_change(self):
        self.plugin.appear("wb")
        self.deck.feedback("wb", "5600K")
        marker = self.deck.mark()
        self.plugin.rotate("wb")
        self.deck.feedback("wb", "5700K", after=marker)
        self.assertEqual(self.a.value("WBCurrentKelvin"), 5700)
        self.assertEqual(self.a.writes, [{"WBCurrentKelvin": 5700}])
        marker = self.deck.mark()
        self.a.change("WBCurrentKelvin", 6200)
        self.deck.feedback("wb", "6200K", after=marker)
        self.assertEqual(self.b.writes, [])

    def test_offline_feedback_and_recovery(self):
        self.plugin.appear("wb")
        self.deck.feedback("wb", "5600K")
        marker = self.deck.mark()
        self.a.online = False
        self.deck.feedback("wb", "OFFLINE", after=marker)
        marker = self.deck.mark()
        self.a.online = True
        self.deck.feedback("wb", "5600K", after=marker)
        self.assertEqual(self.a.writes, [])

    def test_gang_white_balance_is_absolute_and_resolves_mixed(self):
        self.b.change("WBCurrentKelvin", 3200)
        self.plugin.appear("gang-wb", camera_id="gang")
        self.deck.feedback("gang-wb", "MIXED")
        marker = self.deck.mark()
        self.plugin.rotate("gang-wb")
        feedback = self.deck.feedback("gang-wb", "5700K", after=marker)
        self.assertEqual(feedback["payload"]["target"], "GANG · 2 CAM")
        self.assertEqual(self.a.value("WBCurrentKelvin"), 5700)
        self.assertEqual(self.b.value("WBCurrentKelvin"), 5700)
        self.assertEqual(self.b.writes, [{"WBCurrentKelvin": 5700}])

    def test_gang_ei_maps_each_firmware_enum_by_meaning(self):
        self.b.change("ExposureIndex", 6)  # EI 640 on either firmware.
        self.plugin.appear("gang-ei", parameter="ei", camera_id="gang")
        self.deck.feedback("gang-ei", "MIXED")
        marker = self.deck.mark()
        self.plugin.rotate("gang-ei")
        self.deck.feedback("gang-ei", "1000", after=marker)
        self.assertEqual(self.a.writes, [{"ExposureIndex": 8}])
        self.assertEqual(self.b.writes, [{"ExposureIndex": 7}])

    def test_gang_partial_failure_never_reports_a_false_match(self):
        self.b.change("WBCurrentKelvin", 3200)
        self.b.reject_writes = True
        self.plugin.appear("gang-wb", camera_id="gang")
        self.deck.feedback("gang-wb", "MIXED")
        marker = self.deck.mark()
        self.plugin.rotate("gang-wb")
        self.plugin.assert_alert("gang-wb", after=marker)
        self.assertEqual(self.a.value("WBCurrentKelvin"), 5700)
        self.assertEqual(self.b.value("WBCurrentKelvin"), 3200)
        self.deck.feedback("gang-wb", "MIXED", after=marker)
        values = [message.get("payload", {}).get("value") for message in self.deck.since(marker)
                  if message.get("event") == "setFeedback" and message.get("context") == "gang-wb"]
        self.assertNotIn("5700K", values)
        self.assertFalse(any(message.get("event") == "showOk" for message in self.deck.since(marker)))

    def test_accepted_but_unapplied_write_is_not_reported_as_success(self):
        self.a.accept_without_apply = True
        self.plugin.appear("wb")
        self.deck.feedback("wb", "5600K")
        marker = self.deck.mark()
        self.plugin.rotate("wb")
        self.plugin.assert_alert("wb", after=marker)
        self.assertEqual(self.a.value("WBCurrentKelvin"), 5600)
        self.assertEqual(self.a.writes, [{"WBCurrentKelvin": 5700}])
        self.assertFalse(any(message.get("event") == "setFeedback" and message.get("payload", {}).get("value") == "5700K"
                             for message in self.deck.since(marker)))

    def test_fine_rotation_release_does_not_reset_white_balance(self):
        self.plugin.appear("wb")
        self.deck.feedback("wb", "5600K")
        self.deck.send({"event": "dialDown", "context": "wb", "payload": {"controller": "Encoder"}})
        marker = self.deck.mark()
        self.plugin.rotate("wb", pressed=True)
        self.deck.feedback("wb", "5610K", after=marker)
        self.plugin.release("wb")
        time.sleep(0.6)
        self.assertEqual(self.a.value("WBCurrentKelvin"), 5610)
        self.assertEqual(self.a.writes, [{"WBCurrentKelvin": 5610}])

    def test_clip_buttons_use_verified_fixture_command_ids(self):
        self.plugin.appear("previous", command="previousClip")
        self.plugin.appear("next", command="nextClip")
        self.deck.send({"event": "keyDown", "context": "previous", "payload": {}})
        eventually(lambda: len(self.a.calls) >= 1, "previous clip camera call")
        self.deck.send({"event": "keyDown", "context": "next", "payload": {}})
        eventually(lambda: len(self.a.calls) >= 2, "next clip camera call")
        self.assertEqual(self.a.calls, [
            {"command": "_BJbzscJjEeSbpa7lQ8OAJw", "set": {}},
            {"command": "_H_V7l8JjEeSbpa7lQ8OAJw", "set": {}},
        ])
        self.assertEqual(self.a.writes, [])
        self.assertEqual(self.b.calls, [])

    def test_playback_press_uses_verified_play_and_stop_commands(self):
        self.plugin.appear("playback", parameter="playback")
        self.deck.feedback("playback", "Paused")
        marker = self.deck.mark()
        self.deck.send({"event": "dialDown", "context": "playback", "payload": {"controller": "Encoder"}})
        self.plugin.release("playback")
        self.deck.feedback("playback", "1×", after=marker)
        marker = self.deck.mark()
        self.deck.send({"event": "dialDown", "context": "playback", "payload": {"controller": "Encoder"}})
        self.plugin.release("playback")
        self.deck.feedback("playback", "Paused", after=marker)
        self.assertEqual(self.a.calls, [
            {"command": "_7q_F4cHREeStK8NH8ZPGbQ", "set": {}},
            {"command": "__WRr68HREeStK8NH8ZPGbQ", "set": {}},
        ])
        self.assertEqual(self.a.writes, [])

    def test_rapid_dial_events_preserve_all_requested_ticks(self):
        self.plugin.appear("wb")
        self.deck.feedback("wb", "5600K")
        marker = self.deck.mark()
        for _ in range(10):
            self.plugin.rotate("wb")
        self.deck.feedback("wb", "6600K", after=marker)
        self.assertEqual(self.a.value("WBCurrentKelvin"), 6600)
        self.assertEqual(self.b.writes, [])


class PluginLatencySafetyTests(unittest.TestCase):
    """Latency bounds concern only the loopback mock, never camera hardware."""

    def setUp(self):
        self.a = MockCamera()
        self.addCleanup(self.a.close)
        self.b = MockCamera(different_ei_order=True)
        self.addCleanup(self.b.close)

    def start_plugin(self, *, feedback_mode=None):
        plugin = PluginHarness([("A", "Camera A", self.a.address), ("B", "Camera B", self.b.address)],
                               feedback_mode=feedback_mode)
        self.addCleanup(plugin.close)
        return plugin

    def block_reads(self, camera):
        gate = MockReadGate()
        camera.read_gate = gate
        self.addCleanup(gate.close)
        return gate

    @staticmethod
    def posts(camera, marker=0):
        return [entry for entry in camera.requests_since(marker) if entry["method"] == "POST"]

    def assert_no_confirmed_target(self, deck, context, targets, *, after):
        values = [message.get("payload", {}).get("value") for message in deck.since(after)
                  if message.get("event") == "setFeedback" and message.get("context") == context]
        for target in targets:
            self.assertNotIn(target, values, f"Unconfirmed target {target} displayed as camera feedback")

    def test_warm_cache_sends_command_before_any_new_read(self):
        plugin = self.start_plugin()
        plugin.appear("wb")
        plugin.deck.feedback("wb", "5600K")
        self.a.get_delay_seconds = 1.0
        request_marker = self.a.mark_requests()
        feedback_marker = plugin.deck.mark()
        sent_at = time.monotonic()
        plugin.rotate("wb")
        post = eventually(lambda: self.posts(self.a, request_marker), "warm-cache POST", timeout=0.35)[0]
        latency_ms = (post["at"] - sent_at) * 1000
        entries = self.a.requests_since(request_marker)
        self.assertEqual(entries[0]["method"], "POST", "A fresh snapshot must avoid all pre-command GETs")
        self.assertEqual(post["body"], {"WBCurrentKelvin": 5700})
        self.assertLess(latency_ms, 350, "Dispatch must not wait for the configured one-second GET")
        MOCK_METRICS["warmCacheCommand"] = {
            "scope": "loopback mock only; not a real-camera measurement",
            "configuredSnapshotDelayMilliseconds": 1000,
            "inputToPostArrivalMilliseconds": round(latency_ms, 3),
            "maximumAllowedMilliseconds": 350,
            "newReadsBeforePost": 0,
        }
        plugin.deck.feedback("wb", "5700K", after=feedback_marker)

    def test_next_command_bypasses_blocked_verification_and_preserves_ticks(self):
        plugin = self.start_plugin()
        plugin.appear("wb")
        plugin.deck.feedback("wb", "5600K")
        gate = self.block_reads(self.a)
        marker = plugin.deck.mark()
        plugin.rotate("wb")
        eventually(lambda: len(self.a.writes) == 1, "first command")
        self.assertTrue(gate.entered.wait(timeout=2), "First command should schedule readback")
        sent_at = time.monotonic()
        request_marker = self.a.mark_requests()
        plugin.rotate("wb")
        posts = eventually(lambda: self.posts(self.a, request_marker), "command while prior readback is blocked", timeout=0.35)
        self.assertLess((posts[0]["at"] - sent_at) * 1000, 350)
        self.assertEqual(self.a.writes, [{"WBCurrentKelvin": 5700}, {"WBCurrentKelvin": 5800}])
        time.sleep(0.075)
        self.assert_no_confirmed_target(plugin.deck, "wb", ["5700K", "5800K"], after=marker)
        gate.close()
        plugin.deck.feedback("wb", "5800K", after=marker)

    def test_rapid_play_pause_uses_accepted_intent_while_readback_is_blocked(self):
        # Transport commands can be allowed even when the speed variable cannot
        # be set directly. Rapid presses must not both use the old Paused value.
        with self.a.lock:
            self.a.document["variables"]["PlaybackSpeedEnum"]["readonly"] = True
        plugin = self.start_plugin()
        plugin.appear("playback", parameter="playback")
        plugin.deck.feedback("playback", "Paused")
        gate = self.block_reads(self.a)
        marker = plugin.deck.mark()
        plugin.deck.send({"event": "dialDown", "context": "playback", "payload": {"controller": "Encoder"}})
        plugin.release("playback")
        eventually(lambda: len(self.a.calls) == 1, "first playback command")
        self.assertTrue(gate.entered.wait(timeout=2), "Playback readback should enter the mock gate")
        request_marker = self.a.mark_requests()
        plugin.deck.send({"event": "dialDown", "context": "playback", "payload": {"controller": "Encoder"}})
        plugin.release("playback")
        eventually(lambda: self.posts(self.a, request_marker), "stop command while playback readback is blocked", timeout=0.35)
        self.assertEqual(self.a.calls, [
            {"command": "_7q_F4cHREeStK8NH8ZPGbQ", "set": {}},
            {"command": "__WRr68HREeStK8NH8ZPGbQ", "set": {}},
        ])
        self.assertEqual(self.a.writes, [], "Play/pause must use verified transport commands, never a setting write")
        self.assert_no_confirmed_target(plugin.deck, "playback", ["1×"], after=marker)
        gate.close()
        plugin.deck.feedback("playback", "Paused", after=marker)

    def test_unverified_intent_after_burst_rebases_on_current_camera_value(self):
        plugin = self.start_plugin()
        plugin.appear("wb")
        plugin.deck.feedback("wb", "5600K")
        gate = self.block_reads(self.a)
        plugin.rotate("wb")
        eventually(lambda: len(self.a.writes) == 1, "first accepted white balance command")
        self.assertTrue(gate.entered.wait(timeout=2), "First readback should remain blocked")
        # Exceed the accepted-intent burst lifetime (.75s) while the original
        # confirmed snapshot is still younger than the ordinary cache TTL (2s).
        time.sleep(0.8)
        self.a.change("WBCurrentKelvin", 6400)
        request_marker = self.a.mark_requests()
        feedback_marker = plugin.deck.mark()
        plugin.rotate("wb")
        eventually(lambda: any(entry["method"] == "GET" and entry["path"] == "/all.cgi"
                               for entry in self.a.requests_since(request_marker)),
                   "fresh validation after accepted intent becomes stale", timeout=0.35)
        self.assertEqual(self.posts(self.a, request_marker), [], "An expired intent must not produce an immediate stale-target POST")
        gate.close()
        plugin.deck.feedback("wb", "6500K", after=feedback_marker)
        self.assertEqual(self.a.writes, [{"WBCurrentKelvin": 5700}, {"WBCurrentKelvin": 6500}])

    def test_slow_offline_gang_follower_does_not_stall_camera_a(self):
        plugin = self.start_plugin()
        plugin.appear("gang-wb", camera_id="gang")
        plugin.appear("a-wb")
        plugin.deck.feedback("gang-wb", "5600K")
        plugin.deck.feedback("a-wb", "5600K")
        gate = self.block_reads(self.b)
        self.b.online = False
        self.assertTrue(gate.entered.wait(timeout=2), "Background B snapshot should enter mock gate")
        # B's last confirmed snapshot now expires while A keeps refreshing.
        # The failed/offline follower must never hold A's independent queue.
        time.sleep(1.25)
        marker = self.a.mark_requests()
        plugin.rotate("gang-wb")
        first = eventually(lambda: self.posts(self.a, marker), "A command in gang with slow offline B", timeout=0.35)
        self.assertEqual(first[0]["body"], {"WBCurrentKelvin": 5700})
        marker = self.a.mark_requests()
        plugin.rotate("a-wb")
        second = eventually(lambda: self.posts(self.a, marker), "subsequent independent A command", timeout=0.35)
        self.assertEqual(second[0]["body"], {"WBCurrentKelvin": 5800})
        self.assertEqual(self.b.writes, [])
        gate.close()
        eventually(lambda: self.a.value("WBCurrentKelvin") == 5800, "final A target")

    def test_pending_unapplied_target_never_appears_as_confirmed_feedback(self):
        plugin = self.start_plugin()
        plugin.appear("wb")
        plugin.deck.feedback("wb", "5600K")
        self.a.accept_without_apply = True
        gate = self.block_reads(self.a)
        marker = plugin.deck.mark()
        plugin.rotate("wb")
        eventually(lambda: len(self.a.writes) == 1, "accepted but unapplied command")
        plugin.deck.feedback("wb", "PENDING", after=marker)
        self.assertTrue(gate.entered.wait(timeout=2), "Verification must be scheduled")
        self.assert_no_confirmed_target(plugin.deck, "wb", ["5700K"], after=marker)
        gate.close()
        plugin.assert_alert("wb", after=marker)
        self.assertEqual(self.a.value("WBCurrentKelvin"), 5600)
        self.assertEqual(self.a.writes, [{"WBCurrentKelvin": 5700}], "Readback mismatch must not retry the POST")
        self.assert_no_confirmed_target(plugin.deck, "wb", ["5700K"], after=marker)

    def test_live_feedback_observes_external_changes_without_writes(self):
        plugin = self.start_plugin(feedback_mode="live")
        plugin.appear("wb")
        plugin.deck.feedback("wb", "5600K")
        marker = plugin.deck.mark()
        self.a.change("WBCurrentKelvin", 6300)
        plugin.deck.feedback("wb", "6300K", after=marker)
        self.assertEqual(self.a.writes, [])
        self.assertEqual(self.a.calls, [])
        self.assertEqual(self.b.requests, [], "Only cameras with visible controls need idle polling")

    def test_feedback_off_has_no_idle_reads_but_still_validates_and_confirms_input(self):
        plugin = self.start_plugin(feedback_mode="off")
        plugin.appear("wb")
        time.sleep(1.25)
        self.assertEqual(self.a.requests, [], "Feedback off must not query on appearance or idle timer")
        self.assertEqual(self.b.requests, [])
        marker = plugin.deck.mark()
        plugin.rotate("wb")
        plugin.deck.feedback("wb", "5700K", after=marker)
        entries = self.a.requests_since()
        post_indices = [index for index, entry in enumerate(entries) if entry["method"] == "POST"]
        self.assertEqual(len(post_indices), 1)
        before = entries[:post_indices[0]]
        self.assertEqual(sum(entry["path"] == "/all.cgi" for entry in before), 1,
                         "A cold input needs one validation snapshot, never duplicate pre-reads")
        self.assertTrue(any(entry["method"] == "GET" and entry["path"] == "/all.cgi"
                            for entry in entries[post_indices[0] + 1:]), "Camera confirmation is still required")
        count = self.a.mark_requests()
        time.sleep(1.25)
        self.assertEqual(self.a.mark_requests(), count, "Feedback off must return to zero idle camera traffic")
        self.assertEqual(self.a.writes, [{"WBCurrentKelvin": 5700}])

    def test_existing_copied_action_ids_and_settings_receive_icons_and_feedback(self):
        # These are the original action UUIDs and settings already stored inside
        # copied camera folders. No regenerated profile or new action is sent.
        plugin = self.start_plugin()
        self.assertNotIn("feedbackMode", plugin.config, "Legacy saved configs exercise the default live mode")
        plugin.appear("copied-dial", action_uuid="com.atomfilmlab.camera-control.dial")
        plugin.appear("copied-next", command="nextClip", action_uuid="com.atomfilmlab.camera-control.button")
        for context in ["copied-dial", "copied-next"]:
            plugin.deck.wait(lambda message: message.get("event") == "setImage"
                             and message.get("context") == context and message.get("payload", {}).get("image"),
                             f"dynamic icon for unchanged copied action {context}")
        plugin.deck.feedback("copied-dial", "5600K")
        marker = plugin.deck.mark()
        self.a.change("WBCurrentKelvin", 6100)
        plugin.deck.feedback("copied-dial", "6100K", after=marker)
        self.assertEqual(self.a.writes, [])
        self.assertEqual(self.a.calls, [])

    def test_appearance_settings_polling_and_recovery_never_send_commands(self):
        plugin = self.start_plugin()
        plugin.appear("wb")
        plugin.appear("clip", command="nextClip")
        plugin.deck.feedback("wb", "5600K")
        plugin.deck.send({"event": "didReceiveSettings", "context": "wb", "payload": {
            "settings": {"cameraID": "A", "parameter": "wb"}, "controller": "Encoder"}})
        self.a.change("WBCurrentKelvin", 6400)
        plugin.deck.feedback("wb", "6400K")
        marker = plugin.deck.mark()
        self.a.online = False
        plugin.deck.feedback("wb", "OFFLINE", after=marker)
        marker = plugin.deck.mark()
        self.a.online = True
        plugin.deck.feedback("wb", "6400K", after=marker)
        self.assertEqual(self.posts(self.a), [], "Only an explicit foreground control input can issue a POST")
        self.assertEqual(self.posts(self.b), [])


class HardwareWhiteBalanceDiagnostic(unittest.TestCase):
    def test_plugin_white_balance_step_and_verified_restore(self):
        """Explicit opt-in only: one WB step, then restore via the same plugin."""
        self.assertIsNotNone(HARDWARE_ADDRESS)
        initial = camera_read(HARDWARE_ADDRESS)
        original = initial["variables"]["WBCurrentKelvin"]["value"]
        HARDWARE_EVIDENCE["originalKelvin"] = original
        maximum = initial["variables"]["WBCurrentKelvin"]["max"]
        self.assertLessEqual(original + 100, maximum, "Camera WB cannot take the authorized +100K step")
        plugin = PluginHarness([("A", "Hardware WB diagnostic", HARDWARE_ADDRESS)])
        changed = False
        try:
            plugin.appear("hardware-wb")
            plugin.deck.feedback("hardware-wb", f"{original:g}K")
            marker = plugin.deck.mark()
            # Record intent before sending: a timeout must still restore a
            # change that reached the camera without feedback reaching us.
            changed = True
            plugin.rotate("hardware-wb", 1)
            plugin.deck.feedback("hardware-wb", f"{original + 100:g}K", after=marker)
            actual = camera_read(HARDWARE_ADDRESS)["variables"]["WBCurrentKelvin"]["value"]
            self.assertEqual(actual, original + 100)
            HARDWARE_EVIDENCE["steppedFeedbackKelvin"] = original + 100
            HARDWARE_EVIDENCE["steppedReadbackKelvin"] = actual
            print(f"Hardware WB feedback and readback: {actual:g}K", flush=True)
        finally:
            try:
                if changed:
                    current = camera_read(HARDWARE_ADDRESS)["variables"]["WBCurrentKelvin"]["value"]
                    if current != original:
                        # Restore only the authorized single step. Do not make
                        # speculative adjustments if another operator changed WB.
                        self.assertEqual(current, original + 100,
                                         "WB changed unexpectedly; refusing an unplanned restoration step")
                        marker = plugin.deck.mark()
                        plugin.rotate("hardware-wb", -1)
                        plugin.deck.feedback("hardware-wb", f"{original:g}K", after=marker)
                    restored = camera_read(HARDWARE_ADDRESS)["variables"]["WBCurrentKelvin"]["value"]
                    self.assertEqual(restored, original, "Original hardware WB was not restored")
                    HARDWARE_EVIDENCE["restoredReadbackKelvin"] = restored
                    print(f"Hardware WB restored and verified: {restored:g}K", flush=True)
            finally:
                plugin.close()


def main():
    global EXECUTABLE, HARDWARE_ADDRESS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=DEFAULT_EXECUTABLE)
    parser.add_argument("--hardware-address", help="Explicit opt-in: run ONLY real-camera WB +100K and restore through the plugin")
    parser.add_argument("--report", type=Path, help="Write a small JSON verification report")
    arguments = parser.parse_args()
    EXECUTABLE = arguments.executable.resolve()
    HARDWARE_ADDRESS = arguments.hardware_address
    if not EXECUTABLE.is_file():
        parser.error(f"Native plugin executable does not exist: {EXECUTABLE}")
    cases = [HardwareWhiteBalanceDiagnostic] if HARDWARE_ADDRESS else [MockPluginIntegrationTests, PluginLatencySafetyTests]
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case) for case in cases)
    start = time.monotonic()
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {"mode": "hardware-white-balance-step-and-restore" if HARDWARE_ADDRESS else "loopback-mocks",
              "executable": str(EXECUTABLE), "testsRun": result.testsRun,
              "failures": len(result.failures), "errors": len(result.errors),
              "durationSeconds": round(time.monotonic() - start, 3), "passed": result.wasSuccessful()}
    if HARDWARE_EVIDENCE:
        report["evidence"] = HARDWARE_EVIDENCE
    if MOCK_METRICS:
        report["mockMetrics"] = MOCK_METRICS
    if arguments.report:
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
