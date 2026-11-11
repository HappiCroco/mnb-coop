#!/usr/bin/env python3
"""
Mud and Blood Co-op Helper
==========================
External networking helper for the M&B co-op mod.
Communicates with Lua via JSON files in the coop directory.

Protocol:
- Reads commands from:  coop/cmd.json
- Writes responses to: coop/data.json
"""

import json
import os
import socket
import time
import sys

# Configuration
DEFAULT_PORT = 12345
BUFFER_SIZE = 4096
COOP_DIR = os.path.join(os.path.expanduser("~"), "AppData", "Roaming", "LOVE", "mnb", "coop")

if not os.path.exists(COOP_DIR):
    COOP_DIR = os.path.join(os.getcwd(), "coop")

CMD_FILE = os.path.join(COOP_DIR, "cmd.json")
DATA_FILE = os.path.join(COOP_DIR, "data.json")

# State
mode = None
server_socket = None
client_socket = None
running = True
connected = False
last_cmd_time = 0


def ensure_dir():
    os.makedirs(COOP_DIR, exist_ok=True)


def read_cmd():
    """Read and parse cmd.json. Returns None if file doesn't exist or is stale."""
    if not os.path.exists(CMD_FILE):
        return None

    try:
        mtime = os.path.getmtime(CMD_FILE)
        if mtime <= last_cmd_time:
            return None
        last_cmd_time = mtime

        with open(CMD_FILE, "r") as f:
            content = f.read().strip()
            if not content:
                return None
            return json.loads(content)
    except (json.JSONDecodeError, IOError, OSError):
        return None


def write_data(data):
    """Write response to data.json."""
    try:
        with open(DATA_FILE, "w") as f:
            json.dump(data, f)
    except IOError:
        pass


def host_server(port):
    """Host a server and wait for a client to connect."""
    global server_socket, client_socket, connected

    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind(("", port))
    server_socket.listen(1)
    server_socket.settimeout(1.0)

    print(f"[COOP] Hosting on port {port}...")
    write_data({"status": "hosting", "port": port})

    while running and not connected:
        try:
            client, addr = server_socket.accept()
            client_socket = client
            connected = True
            print(f"[COOP] Client connected: {addr}")
            write_data({"status": "connected", "peer": str(addr)})
            break
        except socket.timeout:
            continue
        except OSError:
            break

    if connected:
        handle_connection(client_socket, is_host=True)


def join_server(host, port):
    """Connect to a host server."""
    global client_socket, connected

    print(f"[COOP] Connecting to {host}:{port}...")
    write_data({"status": "connecting", "host": host})

    try:
        client_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        client_socket.settimeout(5.0)
        client_socket.connect((host, port))
        client_socket.settimeout(0.5)
        connected = True
        print(f"[COOP] Connected to host")
        write_data({"status": "connected", "host": host})
        handle_connection(client_socket, is_host=False)
    except (socket.timeout, ConnectionRefusedError, OSError) as e:
        print(f"[COOP] Connection failed: {e}")
        write_data({"status": "error", "message": str(e)})


def handle_connection(sock, is_host):
    """Handle an established connection."""
    global running, connected

    sock.settimeout(0.5)

    while running and connected:
        try:
            # Check for incoming network data
            data = sock.recv(BUFFER_SIZE)
            if not data:
                print("[COOP] Connection closed by peer")
                connected = False
                write_data({"status": "disconnected"})
                break

            try:
                msg = json.loads(data.decode("utf-8"))
                write_data(msg)
            except json.JSONDecodeError:
                pass

        except socket.timeout:
            pass
        except OSError:
            break

        # Check for commands from Lua mod
        cmd = read_cmd()
        if cmd:
            if cmd.get("action") == "quit":
                print("[COOP] Quit command received")
                break
            elif cmd.get("action") == "state" and is_host:
                # Host sends state to client
                try:
                    sock.sendall(json.dumps(cmd).encode("utf-8"))
                except OSError:
                    connected = False
                    break

        time.sleep(0.01)

    print("[COOP] Connection handler exiting")


def cleanup():
    """Clean up sockets."""
    global running, connected, server_socket, client_socket

    running = False
    connected = False

    for s in [client_socket, server_socket]:
        if s:
            try:
                s.close()
            except OSError:
                pass

    print("[COOP] Helper stopped")


def main():
    global mode

    ensure_dir()
    print("[COOP] Helper started, waiting for commands...")

    # Wait for initial command from Lua mod
    for _ in range(100):  # Wait up to 10 seconds
        cmd = read_cmd()
        if cmd:
            mode = cmd.get("action")
            break
        time.sleep(0.1)

    if not mode:
        print("[COOP] No initial command received, exiting")
        return

    try:
        if mode == "host":
            host_server(cmd.get("port", DEFAULT_PORT))
        elif mode == "client":
            join_server(cmd.get("host", "localhost"), cmd.get("port", DEFAULT_PORT))
        else:
            print(f"[COOP] Unknown mode: {mode}")
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()


if __name__ == "__main__":
    main()
