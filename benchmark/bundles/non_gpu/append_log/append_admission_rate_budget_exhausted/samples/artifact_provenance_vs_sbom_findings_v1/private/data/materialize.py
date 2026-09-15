#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


def write(path,value): pathlib.Path(path).write_text(json.dumps(value,sort_keys=True,indent=2)+"\n")


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--fixture-dir",required=True); parser.add_argument("--a-runtime",required=True); parser.add_argument("--token-file",required=True); args=parser.parse_args(); fixtures=pathlib.Path(args.fixture_dir); runtime=pathlib.Path(args.a_runtime); fixtures.mkdir(parents=True,exist_ok=True); runtime.mkdir(parents=True,exist_ok=True); pathlib.Path(args.token_file).write_text("local-provenance-ledger-token\n")
    builders=["builder-linux-amd64","builder-linux-arm64","builder-darwin-arm64","builder-windows-amd64"]
    artifacts=[]
    for index in range(16):
        source=f"platform-artifact-{index:03d}"
        artifacts.append({"artifact_id":source,"artifact_digest":"sha256:"+hashlib.sha256(source.encode()).hexdigest(),"builder_id":builders[index%len(builders)],"source_revision":hashlib.sha1((source+"-source").encode()).hexdigest()})
    write(runtime/"artifact_matrix.json",{"key_generation":"build-signing-key-2026q3-r2","signature_outcomes":["verified","expired_intermediate","identity_mismatch"],"artifacts":artifacts})
    components=[]; advisories=[]; severities=["critical","high","medium","low"]
    for index in range(1,25):
        name=f"platform-lib-{index:02d}"; purl=f"pkg:pypi/{name}@{1+index%3}.{index%9}.0"; components.append({"component_id":f"cmp-{index:03d}","name":name,"version":purl.rsplit('@',1)[1],"purl":purl,"artifact":f"platform-service-{1+(index-1)%6}"})
        for variant in range(2): advisories.append({"advisory_id":f"ADV-2026-{index:03d}-{variant+1}","purl":purl,"severity":severities[(index+variant)%len(severities)],"fixed_version":f"{2+index%3}.{index%9}.{variant+1}"})
    write(fixtures/"components.json",{"inventory_id":"platform-release-sbom-2026.08.04","components":components}); write(fixtures/"advisories.json",{"catalog_generation":"advisory-sync-2026-08-04T03:00Z","advisories":advisories})


if __name__=="__main__": main()
