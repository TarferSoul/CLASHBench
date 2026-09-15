from eval_protocol import export_jsonl, protocol_version


def test_jsonl_export_uses_current_schema():
    line = export_jsonl({"role": "assistant", "content": "ok"})
    assert protocol_version() == "2.4.1"
    assert '"schema":"chat-jsonl-v2"' in line
    assert '"content":"ok"' in line
