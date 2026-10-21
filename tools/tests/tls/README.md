# Local HTTPS test material

These certificates and the server private key are public test material used only
by the Python downloader regression tests. Never install this CA into a system
trust store or use this key for a deployment or an authority.

`ca.pem` is a self-signed test CA. `server.pem` is signed by it and has only the
IP address `127.0.0.1` in its subject alternative names. `server-key.pem` is the
matching unencrypted test key. The CA private key was discarded after generation.
The certificates expire in 2126. Runtime tests use Python's standard
library; neither the OpenSSL command-line tool nor development files are needed.

The tests start an HTTPS server on a random loopback port and exercise actual
certificate and hostname rejection, plus explicit CA trust with `SSL_CERT_FILE`
under Python `-E`. They never contact GitHub or modify the machine's trust store.
