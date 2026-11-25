#!/usr/bin/env python3
"""Sparkle appcast for one direct-download build. stdin: the EdDSA private key (base64 seed, vault AZET_PASS_SPARKLE_ED_KEY).
Usage: sparkle-appcast.py DMG VERSION BUILD URL  (--self-test: sign and verify a throwaway file)"""
import base64, email.utils, os, sys, tempfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from xml.sax.saxutils import quoteattr, escape


def appcast(path, version, build, url, seed):
    data = open(path, "rb").read()
    sig = base64.b64encode(Ed25519PrivateKey.from_private_bytes(seed).sign(data)).decode()
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>AZET Pass</title>
<item><title>{escape(version)}</title><pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
<sparkle:version>{escape(build)}</sparkle:version><sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url={quoteattr(url)} length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
</item></channel></rss>
"""


if sys.argv[1:] == ["--self-test"]:
    k = Ed25519PrivateKey.generate(); from cryptography.hazmat.primitives import serialization as s
    seed = k.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())
    with tempfile.NamedTemporaryFile(delete=False) as f: f.write(b"azet"); name = f.name
    xml = appcast(name, "1.0", "1", "https://x/y.dmg", seed); os.unlink(name)
    sig = base64.b64decode(xml.split('sparkle:edSignature="')[1].split('"')[0])
    k.public_key().verify(sig, b"azet"); assert 'length="4"' in xml; print("self-test ok")
else:
    seed = base64.b64decode(sys.stdin.read().strip()); assert len(seed) == 32, "the key is not a 32-byte seed"
    sys.stdout.write(appcast(*sys.argv[1:5], seed))
