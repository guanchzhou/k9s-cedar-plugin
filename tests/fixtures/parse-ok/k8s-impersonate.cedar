permit (
  principal is k8s::User,
  action in [k8s::Action::"impersonate"],
  resource is k8s::ServiceAccount
) when {
  principal.name == "test-user" &&
  resource has namespace &&
  resource.namespace == "default" &&
  resource.name == "service-manager"
};
permit (
  principal is k8s::ServiceAccount,
  action,
  resource is k8s::Resource
) when {
  principal.name == "service-manager" &&
  resource.resource == "services" &&
  resource has namespace &&
  resource.namespace == principal.namespace
};
