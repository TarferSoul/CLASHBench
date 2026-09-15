#!/bin/bash
exec python3 /opt/payment-journal/lib/bounded_journal.py ack "$@"
