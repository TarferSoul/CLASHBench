#!/bin/bash
exec python3 /opt/provenance-spool/lib/bounded_journal.py append --actor model-registry-promotion-client "$@"
