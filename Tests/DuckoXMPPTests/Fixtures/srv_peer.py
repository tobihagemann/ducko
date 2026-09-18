import socket
import struct
import threading


class DirectTLSSRVPeer:
    def __init__(self, port):
        self.port = port
        self.queried = False
        self.stopped = threading.Event()
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(('127.0.0.1', 53535))
        self.socket.settimeout(0.1)
        self.thread = threading.Thread(target=self.run)
        self.thread.start()

    def run(self):
        while not self.stopped.is_set():
            try:
                request, address = self.socket.recvfrom(4096)
            except socket.timeout:
                continue
            labels, offset = [], 12
            while request[offset]:
                count = request[offset]
                labels.append(request[offset + 1:offset + 1 + count].decode('ascii').lower())
                offset += count + 1
            offset += 1
            kind, record_class = struct.unpack('!HH', request[offset:offset + 4])
            question = request[12:offset + 4]
            answer = b''
            if labels == ['_xmpps-client', '_tcp', 'registration', 'ducko', 'test'] and kind == 33 and record_class == 1:
                self.queried = True
                value = struct.pack('!HHH', 0, 0, self.port) + b'\x09localhost\x00'
                answer = b'\xc0\x0c' + struct.pack('!HHIH', 33, 1, 0, len(value)) + value
            header = request[:2] + struct.pack('!HHHHH', 0x8400, 1, bool(answer), 0, 0)
            self.socket.sendto(header + question + answer, address)

    def close(self):
        self.stopped.set()
        self.thread.join()
        self.socket.close()
        assert self.queried, 'The production resolver never requested the direct TLS record'
