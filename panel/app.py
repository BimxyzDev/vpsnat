#!/usr/bin/env python3
"""Titik masuk panel web.

Isi sebenarnya ada di `panelapp.py`. Berkas ini sengaja tipis: dijalankan sebagai
skrip, modul ini bernama `__main__`, sedangkan modul halaman meng-`import app`.
Memisahkan keduanya membuat hanya ada SATU objek modul inti per proses, sehingga
router dan registry halaman selalu sinkron (lihat catatan di panelapp.load_pages).

Dipakai sebagai:
    python3 panel/app.py            (systemd: vpsnat-panel)
    python3 panel/app.py hashpw     (hash password admin dari stdin)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import panelapp  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "hashpw":
        print(panelapp.hash_password(sys.stdin.read().rstrip("\r\n")))
        sys.exit(0)
    panelapp.main()
