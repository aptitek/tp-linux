#!/usr/bin/env python3
"""Host-to-Docker Jupyter kernel bridge for TP Linux (tp-linux container)."""

import asyncio
import json
import os
import signal
import subprocess
import sys
from pathlib import Path

CONTAINER_NAME = "tp-linux"
CONTAINER_PYTHON = "/home/student/.local/share/mise/shims/python"
CONTAINER_WORKDIR = "/home/student/workspace"
PORT_KEYS = ("shell_port", "iopub_port", "stdin_port", "control_port", "hb_port")

CONTAINER_RELAY_CODE = """
import socket, sys, threading, time
port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
for _ in range(200):
    try:
        sock.connect(("127.0.0.1", port))
        break
    except OSError:
        time.sleep(0.05)
def pipe_in():
    try:
        while data := sys.stdin.buffer.read1(65536):
            sock.sendall(data)
    except OSError:
        pass
    try:
        sock.shutdown(socket.SHUT_WR)
    except OSError:
        pass
threading.Thread(target=pipe_in, daemon=True).start()
try:
    while chunk := sock.recv(65536):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
except OSError:
    pass
"""


def ensure_container_running(repo_root: Path) -> None:
    res = subprocess.run(
        ["docker", "inspect", "-f", "{{.State.Running}}", CONTAINER_NAME],
        capture_output=True,
        text=True,
        check=False,
    )
    if res.stdout.strip() == "true":
        return
    if res.returncode == 0:
        subprocess.run(["docker", "start", CONTAINER_NAME], check=True, stdout=subprocess.DEVNULL)
        return
    subprocess.run(
        [
            "docker", "run", "-d", "--name", CONTAINER_NAME, "--user", "1000:1000",
            "-e", "TERM=xterm-256color", "-e", "COLORTERM=truecolor", "-p", "8888:8888",
            "-v", f"{repo_root / 'workspace'}:{CONTAINER_WORKDIR}", "-it",
            "--security-opt", "no-new-privileges:true", "--restart", "unless-stopped",
            "tp-linux:local",
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )


async def pipe_stream_to_writer(stream: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await stream.read(65536):
            writer.write(data)
            await writer.drain()
    except OSError:
        pass
    finally:
        writer.close()


async def pipe_reader_to_stdin(reader: asyncio.StreamReader, stdin: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            stdin.write(data)
            await stdin.drain()
    except OSError:
        pass
    finally:
        stdin.close()


async def handle_zmq_client(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter, port: int
) -> None:
    proc = await asyncio.create_subprocess_exec(
        "docker", "exec", "-i", CONTAINER_NAME,
        CONTAINER_PYTHON, "-u", "-c", CONTAINER_RELAY_CODE, str(port),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
    )
    assert proc.stdin is not None and proc.stdout is not None
    await asyncio.gather(
        pipe_reader_to_stdin(reader, proc.stdin),
        pipe_stream_to_writer(proc.stdout, writer),
    )
    await proc.wait()


async def start_port_forwarder(port: int) -> asyncio.AbstractServer:
    return await asyncio.start_server(
        lambda r, w: handle_zmq_client(r, w, port),
        host="127.0.0.1",
        port=port,
        reuse_address=True,
    )


async def run_kernel(kernel_module: str, conn_file: Path) -> int:
    ensure_container_running(Path(__file__).resolve().parent.parent)
    conn_bytes = conn_file.read_bytes()
    conn_data = json.loads(conn_bytes.decode("utf-8"))
    remote_conn = f"/tmp/{conn_file.name}"

    subprocess.run(
        ["docker", "exec", "-i", CONTAINER_NAME, "sh", "-c", f"cat > {remote_conn}"],
        input=conn_bytes,
        check=True,
    )

    servers = [await start_port_forwarder(int(conn_data[k])) for k in PORT_KEYS]
    kernel_proc = await asyncio.create_subprocess_exec(
        "docker", "exec", "-i", "-w", CONTAINER_WORKDIR, CONTAINER_NAME,
        CONTAINER_PYTHON, "-m", kernel_module, "-f", remote_conn,
    )

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, kernel_proc.terminate)

    rc = await kernel_proc.wait()
    for srv in servers:
        srv.close()
    return rc


if __name__ == "__main__":
    os.exit_code = asyncio.run(run_kernel(sys.argv[1], Path(sys.argv[2])))
    sys.exit(os.exit_code)
