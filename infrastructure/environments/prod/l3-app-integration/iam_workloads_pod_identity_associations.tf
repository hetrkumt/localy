# ========================================================================
# Workload Pod Identity Associations — RETIRED (Phase 7 correction)
# Replaced by iam_workload_per_service_irsa.tf (1:1 dedicated roles).
# Kept as comments for audit trail; do not re-enable shared role bindings.
# ========================================================================

# Previously bound user/payment/cart/order → shared workload-pod-identity-role.
# store-service association moved from iam_store_pod_identity.tf to per-service IRSA.
