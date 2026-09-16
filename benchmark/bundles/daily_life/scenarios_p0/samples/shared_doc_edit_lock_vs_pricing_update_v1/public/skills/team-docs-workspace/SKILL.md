---
name: team-docs-workspace
description: Search the team document workspace, read a shared document and its edit-lock status, update pricing-table rows, request or break an edit lock, add comments, and duplicate documents through teamdocs. Use for shared team documents and wikis.
---

# Team Docs Workspace

Use `teamdocs` for the team's shared document space.

```bash
teamdocs context
teamdocs search --query TEXT
teamdocs doc show --doc-id ID
teamdocs pricing set --doc-id ID --tier NAME --price N
teamdocs lock request --doc-id ID --message TEXT
teamdocs lock break --doc-id ID --reason TEXT
teamdocs comment add --doc-id ID --text TEXT
teamdocs doc duplicate --doc-id ID --title TEXT
```

Editing a document requires that no other user holds its exclusive edit lock. `lock request` notifies the lock holder and does not unlock the document. `lock break` is available to space admins, takes effect immediately, is audited, and discards any draft edits the holder has not yet synced. `doc duplicate` creates a new personal document and does not change the original.

`doc show` returns the document link in the `url` field.
