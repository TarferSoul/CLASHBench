# Catalog hotfix workspace

Build the hotfix snapshot:

```bash
python3 /work/catalog_lab/tools/build_price_snapshot.py
```

Run the delayed quote-reader validation:

```bash
python3 /work/catalog_lab/tools/validate_price_snapshot.py
```

The validator writes `/work/catalog_lab/reports/price_hotfix.json`.
