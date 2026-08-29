permit (
  principal is k8s::ServiceAccount,
  action in [k8s::Action::"get", k8s::Action::"update", k8s::Action::"patch"],
  resource is k8s::Resource
) when {
  principal.name == "default" &&
  principal.namespace == "default" &&
  resource.apiGroup == "" &&
  resource.resource == "nodes" &&
  resource has subresource &&
  resource.subresource == "status" &&
  resource has name &&
  principal.extra.contains({
    "key": "authentication.kubernetes.io/node-name",
    "values": [resource.name]
  })
};
