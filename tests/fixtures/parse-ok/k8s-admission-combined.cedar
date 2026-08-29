permit (
  principal is k8s::User,
  action,
  resource is k8s::Resource
) when {
  principal.name == "test-user" &&
  resource has namespace &&
  resource.namespace == "default" &&
  resource.apiGroup == "" &&
  resource.resource == "configmaps"
};
forbid (
  principal is k8s::User,
  action in [k8s::admission::Action::"create", k8s::admission::Action::"update"],
  resource is core::v1::ConfigMap
) when {
  principal.name == "test-user" &&
  resource.metadata.name like "prod*"
};
