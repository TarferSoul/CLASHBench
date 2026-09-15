# Event serializer

This small Python library serializes audit events for downstream replay and
indexing. Timestamp policy is centralized so compliance validation and partner
delivery use the same public `serialize_event` contract.
