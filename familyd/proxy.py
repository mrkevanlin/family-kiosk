"""Lightweight HTTP CONNECT / reverse allowlist proxy for always-allow domains.

When general internet is blocked for the kid UID, Chromium can be pointed at
this proxy (listening on localhost) so Homework and mBlock domains still work.
On Ubuntu the kid process talks to 127.0.0.1:8888 which is exempt from the
nftables UID reject.

In dry-run / Mac development this module is optional; the UI still works
without it.
"""

from __future__ import annotations

import asyncio
import logging
import re
from typing import Iterable

log = logging.getLogger("familyd.proxy")


def domain_matches(host: str, allowed: Iterable[str]) -> bool:
    host = host.lower().split(":")[0]
    for pattern in allowed:
        p = pattern.lower().lstrip(".")
        if host == p or host.endswith("." + p):
            return True
    return False


class AllowlistProxy:
    def __init__(self, allowed_domains: list[str], listen_host: str = "127.0.0.1", listen_port: int = 8888) -> None:
        self.allowed_domains = allowed_domains
        self.listen_host = listen_host
        self.listen_port = listen_port
        self._server: asyncio.AbstractServer | None = None

    async def start(self) -> None:
        self._server = await asyncio.start_server(
            self._handle, self.listen_host, self.listen_port
        )
        log.info(
            "Allowlist proxy listening on %s:%s (%d domains)",
            self.listen_host,
            self.listen_port,
            len(self.allowed_domains),
        )

    async def stop(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    async def _handle(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            header_bytes = await reader.readuntil(b"\r\n\r\n")
        except Exception:
            writer.close()
            await writer.wait_closed()
            return

        first_line = header_bytes.split(b"\r\n", 1)[0].decode("latin1", errors="replace")
        parts = first_line.split()
        if len(parts) < 2:
            writer.close()
            await writer.wait_closed()
            return

        method, target = parts[0].upper(), parts[1]

        if method == "CONNECT":
            host_port = target
            host, _, port_s = host_port.partition(":")
            port = int(port_s or "443")
            if not domain_matches(host, self.allowed_domains):
                writer.write(b"HTTP/1.1 403 Forbidden\r\n\r\n")
                await writer.drain()
                writer.close()
                await writer.wait_closed()
                return
            try:
                remote_reader, remote_writer = await asyncio.open_connection(host, port)
            except Exception:
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                await writer.drain()
                writer.close()
                await writer.wait_closed()
                return
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            await asyncio.gather(
                _pipe(reader, remote_writer),
                _pipe(remote_reader, writer),
            )
            return

        # Plain HTTP: parse Host header
        host_match = re.search(rb"(?im)^Host:\s*([^\r\n]+)", header_bytes)
        if not host_match:
            writer.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            return
        host = host_match.group(1).decode("latin1").split(":")[0]
        if not domain_matches(host, self.allowed_domains):
            writer.write(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            return

        try:
            remote_reader, remote_writer = await asyncio.open_connection(host, 80)
        except Exception:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            await writer.drain()
            writer.close()
            await writer.wait_closed()
            return

        remote_writer.write(header_bytes)
        await remote_writer.drain()
        await asyncio.gather(
            _pipe(reader, remote_writer),
            _pipe(remote_reader, writer),
        )


async def _pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass
