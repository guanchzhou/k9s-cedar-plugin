permit (
  principal is k8s::User,
  action in [k8s::Action::"list", k8s::Action::"watch"],
  resource is k8s::Resource
) when {
  resource.resource == "secrets" &&
  resource.apiGroup == "" &&
  resource has labelSelector &&
  resource.labelSelector.containsAny([
    {"key": "owner", "operator": "=", "values": [principal.name]},
    {"key": "owner", "operator": "==", "values": [principal.name]},
    {"key": "owner", "operator": "in", "values": [principal.name]}
  ])
};
