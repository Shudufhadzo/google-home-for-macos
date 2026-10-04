#!/usr/bin/env python3
"""Loopback-only, synthetic Home Assistant REST fixture for development/UI checks.

This is not Home Assistant and never connects to physical devices.
"""
import argparse
import copy
import datetime
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "home-manager-local-demo"
LOCK = threading.Lock()
ENTITIES = [
    {"entity_id": "light.demo_desk", "state": "off", "attributes": {"friendly_name": "Demo desk light", "supported_color_modes": ["brightness"], "brightness": 128}},
    {"entity_id": "switch.demo_plug", "state": "off", "attributes": {"friendly_name": "Demo smart plug"}},
    {"entity_id": "climate.demo_room", "state": "heat", "attributes": {"friendly_name": "Demo thermostat", "supported_features": 1, "temperature": 21, "min_temp": 16, "max_temp": 30, "target_temp_step": 0.5, "temperature_unit": "°C"}},
    {"entity_id": "cover.demo_blind", "state": "closed", "attributes": {"friendly_name": "Demo blind", "supported_features": 11}},
    {"entity_id": "vacuum.demo_cleaner", "state": "docked", "attributes": {"friendly_name": "Demo vacuum", "supported_features": 8220}},
    {"entity_id": "fan.demo_fan", "state": "off", "attributes": {"friendly_name": "Demo fan", "supported_features": 49, "percentage": 50}},
    {"entity_id": "sensor.demo_temperature", "state": "22.4", "attributes": {"friendly_name": "Demo temperature", "unit_of_measurement": "°C"}},
    {"entity_id": "scene.demo_evening", "state": "unknown", "attributes": {"friendly_name": "Demo evening scene"}},
    {"entity_id": "light.demo_offline", "state": "unavailable", "attributes": {"friendly_name": "Demo offline bulb", "supported_color_modes": ["onoff"]}},
]
SERVICES = {"light": ["turn_on", "turn_off"], "switch": ["turn_on", "turn_off"],
            "climate": ["set_temperature"], "cover": ["open_cover", "close_cover", "stop_cover"],
            "vacuum": ["start", "pause", "stop", "return_to_base"],
            "fan": ["turn_on", "turn_off", "set_percentage"], "scene": ["turn_on"]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Do not log headers, credentials, or addresses.

    def reply(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.reply(401, {"message": "Fixture token refused"})
            return False
        return True

    def do_GET(self):
        if self.path == "/":
            self.reply(200, {"message": "Synthetic Home Manager development fixture. No physical devices."})
            return
        if not self.authorized():
            return
        if self.path == "/api/states":
            with LOCK:
                self.reply(200, copy.deepcopy(ENTITIES))
        elif self.path == "/api/services":
            self.reply(200, [{"domain": domain, "services": {service: {} for service in services}} for domain, services in SERVICES.items()])
        else:
            self.reply(404, {"message": "Fixture endpoint not found"})

    def do_POST(self):
        if not self.authorized():
            return
        pieces = self.path.strip("/").split("/")
        if len(pieces) != 4 or pieces[:2] != ["api", "services"]:
            self.reply(404, {"message": "Fixture service not found"})
            return
        domain, service = pieces[2:]
        if service not in SERVICES.get(domain, []):
            self.reply(400, {"message": "Unsupported fixture service"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 8192:
                raise ValueError()
            payload = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self.reply(400, {"message": "Invalid fixture request"})
            return
        with LOCK:
            entity = next((entry for entry in ENTITIES if entry["entity_id"] == payload.get("entity_id") and entry["entity_id"].split(".")[0] == domain), None)
            if entity is None or entity["state"] == "unavailable":
                self.reply(400, {"message": "Unavailable fixture entity"})
                return
            states = {"turn_on": "on", "turn_off": "off", "open_cover": "open", "close_cover": "closed", "stop_cover": "stopped",
                      "start": "cleaning", "pause": "paused", "stop": "idle", "return_to_base": "docked"}
            if domain == "scene" and service == "turn_on":
                entity["state"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            elif service in states:
                entity["state"] = states[service]
            for field, attribute, scale in [("brightness_pct", "brightness", 2.55), ("temperature", "temperature", 1), ("percentage", "percentage", 1)]:
                if field in payload:
                    entity["attributes"][attribute] = payload[field] * scale
            self.reply(200, [copy.deepcopy(entity)])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8129)
    arguments = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    print(f"Synthetic fixture ready at http://127.0.0.1:{server.server_port}", flush=True)
    print("Demo token: home-manager-local-demo (fixture only)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
