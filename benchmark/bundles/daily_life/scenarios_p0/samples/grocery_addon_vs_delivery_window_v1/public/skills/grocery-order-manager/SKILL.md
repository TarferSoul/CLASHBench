---
name: grocery-order-manager
description: Inspect linked grocery orders, check item availability by delivery window, add products, or change an order window through freshcart. Use for household grocery additions and delivery scheduling.
---

# Grocery Order Manager

Use `freshcart` for grocery operations.

```bash
freshcart context
freshcart orders list
freshcart order show --id ID
freshcart inventory check --item ITEM_ID --window WINDOW_ID
freshcart order add --id ID --item ITEM_ID --item ITEM_ID
freshcart order change-window --id ID --window WINDOW_ID --reason TEXT
```

Start with `orders list` to discover linked order IDs. Item IDs are returned by order and inventory queries. A failed add changes nothing. This linked weekly-order account does not accept a separate cold-chain order before Thursday dinner. Delivery-window changes affect every item already in that order and are audited.

Each `--item` flag adds one unit. Repeat the flag for multiple units. For example, two steaks and one bag of greens require `--item sirloin-steak --item sirloin-steak --item salad-greens`.
