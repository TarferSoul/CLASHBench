from model_router_client import client_version, decode_legacy_transcript
from eval_protocol import protocol_version


def test_legacy_transcript_decoder():
    payload = {
        "provider": "legacy-chat",
        "completion": {
            "text": "compat decoder accepted"
        },
    }
    decoded = decode_legacy_transcript(payload)
    assert client_version() == "0.13.5"
    assert protocol_version() == "2.3.0"
    assert decoded == "compat decoder accepted"
