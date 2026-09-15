from model_router_client import adapter_name, decode_chat_message, client_version


def test_chat_adapter_uses_openai_compatible_payload():
    payload = {
        "message": {
            "role": "assistant",
            "content": "baseline ready",
        }
    }
    decoded = decode_chat_message(payload)
    assert client_version() == "0.14.2"
    assert adapter_name() == "openai-compatible-r42"
    assert decoded == {"role": "assistant", "content": "baseline ready"}
