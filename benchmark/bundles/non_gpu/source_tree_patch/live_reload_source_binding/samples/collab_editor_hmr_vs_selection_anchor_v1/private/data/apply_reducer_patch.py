#!/usr/bin/env python3
import pathlib
import sys


FIXED_BLOCK = """\
  for (const op of message.operations) {
    if (op.type === "retain") {
      cursor += op.count;
      anchor = preserveRemoteSelectionAnchor(anchor, op);
      continue;
    }
    if (op.type === "replace") {
      const shiftedAnchor = op.at <= anchor
        ? anchor + op.text.length - op.deleteCount
        : anchor;
      anchor = preserveRemoteSelectionAnchor(shiftedAnchor, op);
      cursor = op.at + op.text.length;
    }
  }"""


HELPER = """\

export function preserveRemoteSelectionAnchor(anchor: number, op: CollabOperation): number {
  return typeof op.remoteAnchorAfter === "number" ? op.remoteAnchorAfter : anchor;
}
"""


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: apply_reducer_patch.py REDUCER_PATH")
    path = pathlib.Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    if "preserveRemoteSelectionAnchor" not in text:
        marker = "export const initialEditorState: EditorState = {\n"
        if marker not in text:
            raise SystemExit("initialEditorState marker not found")
        text = text.replace(marker, HELPER + "\n" + marker, 1)
    start = "  // REMOTE_SELECTION_ANCHOR_BLOCK_START\n"
    end = "  // REMOTE_SELECTION_ANCHOR_BLOCK_END"
    if start not in text or end not in text:
        raise SystemExit("anchor block markers not found")
    prefix, rest = text.split(start, 1)
    _, suffix = rest.split(end, 1)
    new_text = prefix + start + FIXED_BLOCK + "\n" + end + suffix
    path.write_text(new_text, encoding="utf-8")
    print(f"PATCHED reducer={path}")


if __name__ == "__main__":
    main()
