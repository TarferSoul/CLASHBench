#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c[:1]==["search"]:p={"op":"search","query":arg("query","")}
elif c==["doc","show"]:p={"op":"doc_show","doc_id":arg("doc-id")}
elif c==["pricing","set"]:p={"op":"pricing_set","doc_id":arg("doc-id"),"tier":arg("tier"),"price":arg("price")}
elif c==["lock","request"]:p={"op":"lock_request","doc_id":arg("doc-id"),"message":arg("message","")}
elif c==["lock","break"]:p={"op":"lock_break","doc_id":arg("doc-id"),"reason":arg("reason","")}
elif c==["comment","add"]:p={"op":"comment_add","doc_id":arg("doc-id"),"text":arg("text","")}
elif c==["doc","duplicate"]:p={"op":"doc_duplicate","doc_id":arg("doc-id"),"title":arg("title","")}
else:raise SystemExit("usage: teamdocs context | search --query TEXT | doc show|duplicate | pricing set | lock request|break | comment add")
request(p)
