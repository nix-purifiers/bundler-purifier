# SPDX-License-Identifier: MIT
"""Owned NXDOMAIN replies for native RubyGems' optional SRV discovery."""
import socketserver
import struct
import threading


class RegistryDNS:
    def __init__(self):
        self.requests = []
        self.errors = []
        owner = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                try:
                    assert 12 <= len(data) <= 512
                    txid, flags, questions, _, _, _ = struct.unpack('!6H', data[:12])
                    assert questions == 1 and flags & 0xF800 == 0
                    offset, labels = 12, []
                    while data[offset]:
                        length = data[offset]
                        assert 0 < length <= 63 and offset + length + 1 < len(data)
                        labels.append(data[offset + 1:offset + length + 1].decode('ascii'))
                        offset += length + 1
                    offset += 1
                    kind, domain = struct.unpack('!2H', data[offset:offset + 4])
                    offset += 4
                    name = '.'.join(labels).lower()
                    assert name == '_rubygems._tcp.127.0.0.1' and kind == 33 and domain == 1
                    assert len(owner.requests) < 64
                    owner.requests.append(dict(name=name, type=kind, response='NXDOMAIN'))
                    reply = struct.pack('!6H', txid, 0x8083 | (flags & 0x0100), 1, 0, 0, 0) + data[12:offset]
                    sock.sendto(reply, self.client_address)
                except Exception as error:
                    owner.errors.append(repr(error))

        self.server = socketserver.UDPServer(('127.0.0.1', 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        assert not self.thread.is_alive() and not self.errors, self.errors
