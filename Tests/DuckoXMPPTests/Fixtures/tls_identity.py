import datetime
import hashlib
import subprocess


def make_identity(directory, mode):
    def openssl(*arguments):
        subprocess.run(["/usr/bin/openssl", *arguments], check=True,
                       cwd=directory, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
            "-keyout", "root.key", "-out", "root.pem", "-subj", "/CN=Ducko local TLS test root",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key",
            "-out", "server.csr", "-subj", "/CN=localhost")
    names = "DNS:localhost,DNS:registration.ducko.test" if mode == 'registration-direct' else "DNS:localhost"
    if mode.startswith('ip-') and mode != 'ip-dns-only':
        names = 'IP:127.0.0.2' if mode in ('ip-override', 'ip-wrong') else 'IP:127.0.0.1'
    (directory / "leaf.ext").write_text("basicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\nsubjectAltName=" + names + "\n")
    openssl("x509", "-req", "-in", "server.csr", "-CA", "root.pem", "-CAkey", "root.key",
            "-CAcreateserial", "-out", "server.pem", "-days", "2", "-sha256", "-extfile", "leaf.ext")
    openssl("x509", "-in", "root.pem", "-outform", "DER", "-out", "root.der")


def identity_metadata(root):
    leaf_der = subprocess.check_output(["/usr/bin/openssl", "x509", "-in", str(root / "server.pem"), "-outform", "DER"])
    expiry = subprocess.check_output(["/usr/bin/openssl", "x509", "-in", str(root / "server.pem"), "-enddate", "-noout"], text=True).strip().split("=", 1)[1]
    expiry = datetime.datetime.strptime(expiry, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
    return leaf_der, {'rootPath': str(root / 'root.der'), 'fingerprint': hashlib.sha256(leaf_der).hexdigest(), 'expiry': expiry.timestamp()}
