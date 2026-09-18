import json
import pathlib
import socket
import ssl
import sys
import tempfile
import time
from tls_identity import make_identity, identity_metadata
from stream_reader import StreamReader

def receive_exactly(connection, count):
    data = bytearray()
    while len(data) < count:
        chunk = connection.recv(count - len(data))
        assert chunk, "Unexpected end of stream"
        data.extend(chunk)
    return bytes(data)


scenario = sys.argv[1]
mode = ('starttls' if scenario == 'ip-starttls' else 'direct') if scenario.startswith('ip-') else scenario
ip_failure = scenario in ('ip-wrong', 'ip-dns-only', 'ip-untrusted', 'ip-dns-account')
temporary = tempfile.TemporaryDirectory(prefix="ducko-tls-test-")
root = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path(temporary.name)
if len(sys.argv) == 2:
    make_identity(root, scenario)
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(1)
listener.settimeout(8)
_, metadata = identity_metadata(root)
print(json.dumps(dict(metadata, port=listener.getsockname()[1])), flush=True)
opening = b"<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
try:
    client, _ = listener.accept()
    client.settimeout(6)
    with client:
        if mode == 'stopplain':
            client.sendall(b'ready')
            assert receive_exactly(client, len(b'after-stop')) == b'after-stop'
            client.sendall(b'late')
            sys.exit(0)
        if mode not in ('direct', 'stoptls', 'wronghost', 'tls12', 'tls13', 'tls11', 'abandonedhandshake'):
            reader = StreamReader(client)
            reader.opened()
            features = opening + b'<stream:features>'
            if mode != 'plaintext':
                features += b"<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
            client.sendall(features + b'</stream:features>')
            if mode == 'plaintext':
                assert receive_exactly(client, len(b'plain-probe')) == b'plain-probe'
                client.sendall(b"<message><body>plain-reply</body></message>")
                assert client.recv(4096) == b''
                sys.exit(0)
            assert reader.stanza().tag == '{urn:ietf:params:xml:ns:xmpp-tls}starttls'
            proceed = b"<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
            if mode == 'contaminated':
                client.sendall(proceed + b'<message><body>bad</body></message>')
                assert client.recv(4096) == b''
                sys.exit(0)
            if mode == 'split':
                client.sendall(proceed[:17])
                time.sleep(0.02)
                client.sendall(proceed[17:])
            else:
                client.sendall(proceed)
            if mode == 'stalledtls':
                while client.recv(4096): pass
                sys.exit(0)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        versions = {'tls12': ssl.TLSVersion.TLSv1_2, 'tls13': ssl.TLSVersion.TLSv1_3, 'tls11': ssl.TLSVersion.TLSv1_1}
        if mode in versions:
            assert ssl.HAS_TLSv1_3, ssl.OPENSSL_VERSION
            context.minimum_version = context.maximum_version = versions[mode]
            if mode == 'tls11':
                context.set_ciphers('DEFAULT:@SECLEVEL=0')
        context.load_cert_chain(root/'server.pem', root/'server.key')
        context.set_alpn_protocols(['xmpp-client'])
        sni = []
        def observe_sni(connection, name, context):
            sni.append(name)
        context.set_servername_callback(observe_sni)
        with context.wrap_socket(client, server_side=True) as secure:
            assert mode != 'tls11', 'TLS 1.1 was accepted'
            if mode in versions:
                assert secure.version() == {'tls12': 'TLSv1.2', 'tls13': 'TLSv1.3'}[mode]
            assert not ip_failure, 'An invalid account identity was accepted'
            if scenario.startswith('ip-'):
                assert sni == [None], sni
            if mode == 'abandonedhandshake':
                assert secure.recv(4096) == b''
                sys.exit(0)
            if mode == 'stoptls':
                secure.sendall(b'ready')
                assert receive_exactly(secure, len(b'after-stop')) == b'after-stop'
                secure.sendall(b'late')
                sys.exit(0)
            StreamReader(secure).opened()
            assert secure.selected_alpn_protocol() == 'xmpp-client'
            secure.sendall(opening + b'<stream:features/>')
            assert receive_exactly(secure, len(b'secure-probe')) == b'secure-probe'
            secure.sendall(b"<message><body>secure-reply</body></message>")
            assert secure.recv(4096) == b''
except (ConnectionResetError, BrokenPipeError, ssl.SSLError) as error:
    if mode not in ('contaminated', 'stalledtls', 'untrusted', 'wronghost', 'tls11') and not ip_failure: raise
    if mode == 'tls11':
        assert isinstance(error, ssl.SSLError) and error.reason == 'UNSUPPORTED_PROTOCOL', error
    if mode == 'wronghost':
        assert sni == ['wrong.invalid'], sni
finally:
    listener.close()
    temporary.cleanup()
