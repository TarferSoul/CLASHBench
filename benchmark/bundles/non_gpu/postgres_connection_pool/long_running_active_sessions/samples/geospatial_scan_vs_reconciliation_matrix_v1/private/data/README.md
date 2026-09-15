The PostgreSQL fixture is generated at runtime from private/db/init.sql.

The data models a software analytics warehouse for a SaaS metrics service:
customers, subscriptions, invoices, and usage events. It is synthetic and small
enough for bounded sandbox validation, while still large enough for A's active
read-only report sections to remain in flight during B's bounded archive task.
