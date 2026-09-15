from parser import normalize_release_tag

assert normalize_release_tag(" RC_2026_08 ") == "rc-2026-08"
