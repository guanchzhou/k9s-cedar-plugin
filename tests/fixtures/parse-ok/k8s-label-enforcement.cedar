permit (
  principal is k8s::User,
  action in [
    k8s::Action::"create",
    k8s::Action::"list",
    k8s::Action::"watch",
    k8s::Action::"update",
    k8s::Action::"patch",
    k8s::Action::"delete"
  ],
  resource is k8s::Resource
) when {
  principal.name == "sample-user" &&
  resource has namespace &&
  resource.namespace == "default" &&
  resource.apiGroup == "" &&
  resource.resource == "configmaps"
};
forbid (
  principal is k8s::User in k8s::Group::"requires-labels",
  action in [k8s::Action::"list", k8s::Action::"watch"],
  resource is k8s::Resource
) unless {
  resource has labelSelector &&
  resource.labelSelector.containsAny([
    {"key": "owner", "operator": "=", "values": [principal.name]},
    {"key": "owner", "operator": "==", "values": [principal.name]},
    {"key": "owner", "operator": "in", "values": [principal.name]}
  ])
};
forbid (
  principal is k8s::User in k8s::Group::"requires-labels",
  action in [k8s::admission::Action::"create", k8s::admission::Action::"update", k8s::admission::Action::"delete"],
  resource
) unless {
  resource has metadata &&
  resource.metadata has labels &&
  resource.metadata.labels.contains({"key": "owner", "value": principal.name})
};
