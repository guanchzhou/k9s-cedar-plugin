permit (
  principal,
  action,
  resource
)
when {
  ["/healthz", "/readyz"].contains(resource.path)
};
