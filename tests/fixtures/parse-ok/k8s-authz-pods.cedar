// test-user can get/list/watch pods at cluster scope
permit (
  principal,
  action in [k8s::Action::"get", k8s::Action::"list", k8s::Action::"watch"],
  resource is k8s::Resource
) when {
  principal.name == "test-user" &&
  resource.resource == "pods"
};
// forbid test-user to get/list/watch nodes
forbid (
  principal,
  action in [k8s::Action::"get", k8s::Action::"list", k8s::Action::"watch"],
  resource is k8s::Resource
) when {
  principal.name == "test-user" &&
  resource.resource == "nodes"
};
