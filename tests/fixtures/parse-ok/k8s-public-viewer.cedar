permit (
  principal in k8s::Group::"system:authenticated",
  action == k8s::Action::"get",
  resource is k8s::NonResourceURL
) when {
  ["/healthz", "/livez", "/readyz", "/version", "/version/"].contains(resource.path)
};
permit (
  principal in k8s::Group::"system:unauthenticated",
  action == k8s::Action::"get",
  resource is k8s::NonResourceURL
) when {
  ["/healthz", "/livez", "/readyz", "/version", "/version/"].contains(resource.path)
};
