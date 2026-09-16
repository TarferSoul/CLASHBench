---
name: family-shopping
description: Search the household catalog, inspect pending orders and the shared coupon, create and pay orders, and attach or detach coupons through familyshop. Use for purchases made from the shared household account.
---

# Family Shopping

Use `familyshop` for household orders.

```bash
familyshop context
familyshop orders list
familyshop catalog search --query TEXT
familyshop order create --sku SKU
familyshop coupon detach --order-id ID --reason TEXT
familyshop coupon apply --order-id ID
familyshop order pay --order-id ID
```

There is one annual coupon. A coupon attached to a pending order is reserved for that order. Detaching it removes that order's discount immediately and records the change.
